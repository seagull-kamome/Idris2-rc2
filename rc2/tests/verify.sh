#!/usr/bin/env bash
# One-shot correctness verification for rc2: builds the compiler and
# runtime, runs the refc-suite regression tests, compiles and diffs
# every smoke test (rc2/tests/Test*.idr) against a saved expected
# output (rc2/tests/TestN.expected), and runs `valgrind
# --leak-check=full` on the leak-sensitive subset -- all the steps
# rc2/doc/*.md's own "Verification methodology" sections and past
# sessions have done by hand, in one deterministic, exit-code-driven
# script. See KNOWN-BUGS.md for every already-investigated quirk this
# script deliberately does NOT flag as a failure (pre-existing leak
# byte counts, Test7CastMatrix's own nixpkgs-RefC-library blocker,
# etc.) -- if KNOWN-BUGS.md changes, update the constants below to
# match.
#
# Usage: ./verify.sh [--skip-build] [--no-valgrind] [--valgrind-all]
#                     [--regen-expected] [--directive VALUE]...
#
#   --skip-build       Don't rebuild idris2-rc2/libidris2rc2.a first
#                       (use the existing rc2/build/exec/idris2-rc2).
#   --no-valgrind      Skip the valgrind pass entirely (faster).
#   --valgrind-all     Run valgrind on every smoke test, not just the
#                       curated leak-sensitive subset.
#   --directive VALUE  Forwarded as `--directive VALUE` to idris2-rc2
#                       for every smoke test (rc2/tests/Test*.idr)
#                       compile -- repeatable, same convention as
#                       idris2's own `--directive` (e.g. `--directive
#                       noreuse --directive noconaltnative`). See
#                       Compiler.RC2.RC2's own `toRCDefs` doc comment
#                       (rc2/src/Compiler/RC2/RC2.idr) for the
#                       recognised `no<stagename>` values (noinline/
#                       noreuse/noconaltnative/nomutualloop/noloop/
#                       nodualabi) -- lets a session compare compile/
#                       run time with a given optimisation pass on vs.
#                       off. Not applied to refc-suite (its own run.sh
#                       runs as a separate process, untouched by this
#                       flag). Disabling a stage should never change a
#                       smoke test's own PASS/FAIL outcome -- if it
#                       does, that's a correctness bug in the disabled
#                       stage, not a script bug; report it as a normal
#                       FAIL rather than special-casing it.
#   --regen-expected   Rebuild each smoke test with real `idris2 --cg
#                       refc` too, and overwrite its own
#                       rc2/tests/TestN.expected with that run's
#                       output, before diffing rc2's own output against
#                       it as usual. Slower (every smoke test gets
#                       built twice, once per backend) -- normal runs
#                       skip real refc entirely and just diff against
#                       whatever's already saved. Run this after
#                       editing/adding a Test*.idr whose own expected
#                       output changed, or after adding a brand new
#                       Test*.idr (this script picks up every
#                       Test*.idr under rc2/tests/ automatically, but a
#                       new one has no .expected of its own yet --
#                       without this flag it just reports FAIL "no
#                       saved .expected"). Never touches
#                       Test7CastMatrix.expected or
#                       Test17ConstFold.expected -- those two are saved
#                       by hand instead (real refc can't even build on
#                       this reference nixpkgs for the former; the
#                       latter deliberately diverges by backend on
#                       purpose -- see NO_REFC_DIFF_TESTS below for
#                       both).
#
# Exit code 0 iff every check passed (known pre-existing issues from
# KNOWN-BUGS.md excepted); non-zero otherwise. All output is plain text
# on stdout, PASS/FAIL/SKIP/KNOWN-prefixed lines, safe to grep. Each
# smoke test's own PASS/FAIL line also carries its compile/run wall-
# clock time -- informational only, never part of the pass/fail
# verdict.
#
# Every generated artifact (compiled binaries, build logs, valgrind
# logs, .diff files) lands under rc2/tests/build/ -- cleaned at the
# very start of a run, then left alone (not deleted on exit) so a
# failure's own compile log/diff/valgrind output is still there to
# read afterward. To rerun or inspect a single test by hand once
# rc2/build/exec/idris2-rc2 exists:
#
#   cd rc2/tests
#   ../build/exec/idris2-rc2 --cg rc2 TestN.idr -o build/exec/TestN_rc2
#   ./build/exec/TestN_rc2                    # compare by eye, or:
#   diff <(cat TestN.expected) <(./build/exec/TestN_rc2)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RC2_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$RC2_DIR/.." && pwd)"
IDRIS2RC2="$RC2_DIR/build/exec/idris2-rc2"

SKIP_BUILD=0
DO_VALGRIND=1
VALGRIND_ALL=0
REGEN_EXPECTED=0
EXTRA_DIRECTIVES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --skip-build) SKIP_BUILD=1; shift ;;
        --no-valgrind) DO_VALGRIND=0; shift ;;
        --valgrind-all) VALGRIND_ALL=1; shift ;;
        --regen-expected) REGEN_EXPECTED=1; shift ;;
        --directive) EXTRA_DIRECTIVES+=("$2"); shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

# Turned into a single ` --directive X --directive Y ...` string,
# spliced straight after `--directive dumprcexpr` in every smoke-test
# compile line below (never sent to refc-suite/run.sh, which runs as
# its own separate process). nix-shell --run "<string>" re-parses that
# whole string inside its own `bash -c`, so this still word-splits
# correctly there -- just don't pass a directive value containing
# whitespace (every recognised rc2 directive is a single identifier).
extra_directive_args=""
for d in "${EXTRA_DIRECTIVES[@]}"; do
    extra_directive_args="$extra_directive_args --directive $d"
done

# Wall-clock elapsed seconds between two `date +%s.%N` samples --
# avoided bash's own `time` builtin since it doesn't compose with the
# `actual="$(...)"` command substitution smoke tests already need to
# capture their own stdout.
elapsed() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.3f", b - a }'; }
timing_note() { echo "compile ${1}s, run ${2}s"; }

# shellcheck source=/dev/null
source "$REPO_DIR/env.sh"

# Every generated artifact lands here -- cleaned now, at the very
# start, then left alone for the rest of this run (and afterward, for
# post-mortem inspection) rather than deleted on exit.
TMP="$RC2_DIR/tests/build"
rm -rf "$TMP"
mkdir -p "$TMP"

pass=0
fail=0
known=0
failed_names=()

report_pass() { echo "PASS  $1"; pass=$((pass + 1)); }
report_fail() { echo "FAIL  $1${2:+ ($2)}"; fail=$((fail + 1)); failed_names+=("$1"); }
report_known() { echo "KNOWN $1 ($2 -- see KNOWN-BUGS.md)"; known=$((known + 1)); }

echo "=== Build ==="
if [ "$SKIP_BUILD" -eq 1 ]; then
    echo "SKIP  build (--skip-build)"
else
    (cd "$RC2_DIR" && nix-shell -p idris2 gmp pkg-config --run 'idris2 --build rc2.ipkg') \
        > "$RC2_DIR/tests/verify-build.log" 2>&1
    if [ $? -ne 0 ]; then
        echo "FAIL  build (see rc2/tests/verify-build.log)"
        exit 1
    fi
    report_pass "build (idris2-rc2)"

    (cd "$RC2_DIR/support/rc2" && nix-shell -p gcc gmp pkg-config --run 'make && make install') \
        > "$RC2_DIR/tests/verify-runtime-build.log" 2>&1
    if [ $? -ne 0 ]; then
        echo "FAIL  build (runtime, see rc2/tests/verify-runtime-build.log)"
        exit 1
    fi
    report_pass "build (libidris2rc2.a)"
fi

echo
echo "=== refc-suite ==="
(cd "$RC2_DIR/tests/refc-suite" && nix-shell -p gcc gmp pkg-config --run './run.sh')
refc_suite_status=$?
if [ "$refc_suite_status" -ne 0 ]; then
    fail=$((fail + 1))
    failed_names+=("refc-suite")
fi

echo
echo "=== Smoke tests ==="

# name -> from inside tests/ as a bare filename (KNOWN-BUGS.md: module
# TestNNNN, not module Main, trips idris2's own module-name check
# otherwise). NO_REFC_DIFF_TESTS skips diffing against real refc in
# favour of a saved .expected file, for two different reasons:
# Test7CastMatrix because nixpkgs' own RefC support library fails to
# compile at all (KNOWN-BUGS.md), Test17ConstFold because its own
# codegenChain deliberately embeds System.Info.codegen's own value (a
# ConstExtPrim regression check) -- "rc2" vs "refc" is real, correct
# divergence between backends, not something to diff away.
BARE_INVOKE_TESTS="Test6NativeInts Test7CastMatrix"
NO_REFC_DIFF_TESTS="Test7CastMatrix Test17ConstFold"

# Leak-sensitive by design (reference-counting/reuse/native-shadow
# regression tests) -- checked with valgrind by default even without
# --valgrind-all.
LEAK_SENSITIVE_TESTS="Test1Basics Test9SelfTailLoop Test10MutualLoop Test11DualABILeak Test12ConAltNative Test13NativeArgChain Test14SmallFunctionInline Test15CompareFusionThroughCall Test16LoopContinuePostDrop"

# KNOWN-BUGS.md's own one remaining pre-existing leak -- "definitely
# lost" byte count, exactly. Anything else non-zero is a genuine new
# failure. (Test9SelfTailLoop's own former 784-byte entry was
# root-caused and fixed -- RLoopContinue's own missing postDrop field,
# see KNOWN-BUGS.md -- and is expected to be clean now.)
declare -A KNOWN_LEAK_BYTES=( [Test1Basics]=40 )

is_in() { local x; for x in $2; do [ "$x" = "$1" ] && return 0; done; return 1; }

ALL_TESTS="$(cd "$RC2_DIR/tests" && ls Test*.idr | sed 's/\.idr$//' | sort)"

for name in $ALL_TESTS; do
    compile_t0="$(date +%s.%N)"
    if is_in "$name" "$BARE_INVOKE_TESTS"; then
        (cd "$RC2_DIR/tests" && nix-shell -p idris2 gcc gmp pkg-config --run \
            "$IDRIS2RC2 --cg rc2 --directive dumprcexpr$extra_directive_args $name.idr -o $TMP/${name}_rc2") \
            > "$TMP/${name}_compile.log" 2>&1
    else
        nix-shell -p idris2 gcc gmp pkg-config --run \
            "$IDRIS2RC2 --cg rc2 --directive dumprcexpr$extra_directive_args $RC2_DIR/tests/$name.idr -o $TMP/${name}_rc2" \
            > "$TMP/${name}_compile.log" 2>&1
    fi
    compile_time="$(elapsed "$compile_t0" "$(date +%s.%N)")"
    if [ ! -x "$TMP/${name}_rc2" ]; then
        report_fail "$name" "rc2 compile error (compile ${compile_time}s), see $TMP/${name}_compile.log"
        continue
    fi

    run_t0="$(date +%s.%N)"
    actual="$("$TMP/${name}_rc2" 2>&1)"
    run_time="$(elapsed "$run_t0" "$(date +%s.%N)")"

    if is_in "$name" "$NO_REFC_DIFF_TESTS"; then
        if [ -f "$RC2_DIR/tests/$name.expected" ]; then
            expected="$(cat "$RC2_DIR/tests/$name.expected")"
            if [ "$actual" = "$expected" ]; then
                report_pass "$name ($(timing_note "$compile_time" "$run_time"); vs. saved .expected, refc diff skipped by design -- see NO_REFC_DIFF_TESTS above)"
            else
                report_fail "$name" "mismatch against saved .expected (compile ${compile_time}s, run ${run_time}s)"
            fi
        else
            report_fail "$name" "no saved .expected, and refc diff is skipped by design for this test -- see NO_REFC_DIFF_TESTS above"
        fi
    else
        expected_file="$RC2_DIR/tests/$name.expected"
        if [ "$REGEN_EXPECTED" -eq 1 ]; then
            if is_in "$name" "$BARE_INVOKE_TESTS"; then
                (cd "$RC2_DIR/tests" && nix-shell -p idris2 gcc gmp pkg-config --run \
                    "idris2 --cg refc $name.idr -o $TMP/${name}_refc") \
                    > "$TMP/${name}_refc_compile.log" 2>&1
            else
                nix-shell -p idris2 gcc gmp pkg-config --run \
                    "idris2 --cg refc $RC2_DIR/tests/$name.idr -o $TMP/${name}_refc" \
                    > "$TMP/${name}_refc_compile.log" 2>&1
            fi
            if [ ! -x "$TMP/${name}_refc" ]; then
                report_fail "$name" "refc compile error, see $TMP/${name}_refc_compile.log"
                continue
            fi
            "$TMP/${name}_refc" > "$expected_file" 2>&1
        fi
        if [ ! -f "$expected_file" ]; then
            report_fail "$name" "no saved .expected -- run with --regen-expected first"
            continue
        fi
        expected="$(cat "$expected_file")"
        if [ "$actual" = "$expected" ]; then
            report_pass "$name (compile ${compile_time}s, run ${run_time}s)"
        else
            diff <(echo "$expected") <(echo "$actual") > "$TMP/${name}.diff"
            report_fail "$name" "output mismatch (compile ${compile_time}s, run ${run_time}s), see $TMP/${name}.diff"
        fi
    fi
done

if [ "$DO_VALGRIND" -eq 1 ]; then
    echo
    echo "=== valgrind (leak-sensitive tests) ==="
    for name in $ALL_TESTS; do
        if [ "$VALGRIND_ALL" -eq 0 ] && ! is_in "$name" "$LEAK_SENSITIVE_TESTS"; then
            continue
        fi
        [ -x "$TMP/${name}_rc2" ] || continue
        nix-shell -p valgrind --run \
            "valgrind --leak-check=full --error-exitcode=1 $TMP/${name}_rc2" \
            > "$TMP/${name}_valgrind.log" 2>&1
        leaked="$(grep -oP 'definitely lost: \K[0-9,]+(?= bytes)' "$TMP/${name}_valgrind.log" | tr -d ',')"
        leaked="${leaked:-0}"
        expected_leak="${KNOWN_LEAK_BYTES[$name]:-0}"
        if [ "$leaked" -eq 0 ]; then
            report_pass "$name (valgrind, 0 bytes definitely lost)"
        elif [ "$leaked" -eq "$expected_leak" ]; then
            report_known "$name (valgrind)" "$leaked bytes definitely lost, matches recorded pre-existing leak"
        else
            report_fail "$name (valgrind)" "$leaked bytes definitely lost (expected 0 or the known $expected_leak) -- see $TMP/${name}_valgrind.log"
        fi
    done
fi

echo
echo "== $pass passed, $known known (pre-existing, see KNOWN-BUGS.md), $fail failed =="
if [ "$fail" -gt 0 ] || [ "$refc_suite_status" -ne 0 ]; then
    [ "${#failed_names[@]}" -gt 0 ] && echo "Failed: ${failed_names[*]}"
    exit 1
fi
exit 0
