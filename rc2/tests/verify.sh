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
#
# VALGRIND_JOBS=N (env var, not a flag) -- how many valgrind runs to
# execute concurrently (default: nproc/2, floored at 1). Each run is
# an independent single-threaded process on its own binary/log file,
# so this parallelizes cleanly; halved from nproc rather than matching
# it because valgrind's own per-process memory overhead is large
# enough that one instance per core risks swapping on a memory-
# constrained machine, which would erase the wall-clock win. Measured
# ~33% faster on the leak-sensitive subset (21 tests) at the default
# of 2 jobs on a 4-core/15GB box vs. the old fully-sequential loop.
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
#
# A smoke test whose own %foreign declarations need a real C
# implementation (not just an rc2/RefC-provided primitive) can supply
# one as TestN.c alongside TestN.idr -- compiled once per run and
# linked in automatically via IDRIS2_CFLAGS/IDRIS2_LDFLAGS. Most tests
# have no such file; this is a no-op for them.

set -u

# Must be run with cwd = this script's own directory (rc2/tests), e.g.
# `cd rc2/tests && ./verify.sh`, NOT `./rc2/tests/verify.sh` from the
# repo root or anywhere else. Most of this script only ever touches
# $RC2_DIR/$REPO_DIR-prefixed absolute paths, so cwd doesn't normally
# matter -- but a handful of tests' own `%cg rc2
# extraRuntime=<relative path>` source pragmas (e.g.
# Test31CgExtraRuntime's `extraRuntime=Test31CgExtraRuntimeSupport.c`)
# get resolved by upstream's own Compiler.Common.getExtraRuntime via a
# plain Core.readFile on that string as-is -- i.e. relative to
# whatever the idris2-rc2 *process's* cwd is at compile time, not
# relative to the source file's own directory. Run from the wrong cwd
# and those tests fail with a misleading "File Not Found" that has
# nothing to do with whatever you were actually testing (confirmed by
# hand: running from the repo root instead of here breaks
# Test31CgExtraRuntime this way). Deliberately NOT `cd`-ed into
# automatically here -- this script won't change a cwd the caller
# didn't ask it to.

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

# libs/rc2base isn't one of nixpkgs' own idris2 packages env.sh's own
# generator (gen-env.sh) draws from -- it's this repo's own local
# package, installed once by hand into its own local prefix (see
# libs/rc2base/README.md's "Build & test" section for the exact
# recipe this mirrors) -- so it's appended here rather than checked
# into env.sh itself, which gen-env.sh would just overwrite on its
# next run.
export IDRIS2_PACKAGE_PATH="$IDRIS2_PACKAGE_PATH:$REPO_DIR/libs/rc2base/.local-install/idris2-0.8.0"

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

# NO_REFC_DIFF_TESTS skips diffing against real refc in favour of a
# saved .expected file, for three different reasons: Test7CastMatrix
# because nixpkgs' own RefC support library fails to compile at all
# (KNOWN-BUGS.md), Test17ConstFold because its own codegenChain
# deliberately embeds System.Info.codegen's own value (a ConstExtPrim
# regression check) -- "rc2" vs "refc" is real, correct divergence
# between backends, not something to diff away -- Test24CStructSupport
# because real RefC doesn't implement getField/setField at all (see
# rc2/doc/c-struct-support.md's "What's confirmed" -- this is the
# exact gap rc2 closes), so there's no real refc output to diff
# against in the first place. Test26GCPtrAliasString is a fourth
# reason: real RefC's own createCFunctions has the identical drop-
# before-pack ordering bug this test regression-checks rc2 for (see
# idris2-src/src/Compiler/RefC/RefC.idr, out of scope to fix there),
# so diffing against it would compare two buggy outputs instead of
# checking against a correctness oracle. Test28Utf8Strings is a fifth
# reason: it regression-checks rc2's own codepoint- (not byte-) indexed
# String primitives, a deliberate divergence from real RefC's own
# byte-wise ones -- see README.md's "Deliberate differences from
# upstream RefC" -- so a real-refc diff would be an expected mismatch,
# not a regression. Its own saved .expected was independently cross-
# checked against plain `idris2` (Chez, the spec-correct reference) for
# every line not involving its own companion-C-only malformed-string
# case (Chez has no `scheme:`-tagged binding for that one test-only
# foreign function, so there is nothing meaningful to diff there).
# Test29GCAnyPtrReturn is a sixth reason, the same shape as
# Test26GCPtrAliasString's: real RefC's own packCFType CFGCPtr case
# (idris2-src/src/Compiler/RefC/RefC.idr:783) has the identical
# GCPointer-vs-plain-Pointer packing mismatch this test regression-
# checks rc2 for -- diffing against it would hit the same bug there
# (out of scope to fix in that separate reference tree) instead of
# checking against a correctness oracle. Test31CgExtraRuntime and
# Test32CgInlineRuntime are a seventh reason, different in kind from
# the others above: real RefC never reads `--directive`/`%cg` at all
# (see README.md's "%cg rc2 directives" section), so their own bare
# %foreign call sites would hit a genuine *link* error under
# `idris2 --cg refc` (the C function their %cg rc2 extraRuntime=/
# inlineRuntime= directive injects for rc2 is simply never defined
# anywhere in RefC's own output) -- not a divergent-but-comparable
# output, so there is nothing to regen/diff against there at all.
# Test35NetworkLoopback is an eighth reason: this pinned reference
# idris2 0.8.0's own RefC codegen has a real bug of its own, unrelated
# to networking or rc2 -- accept()'s own getSockAddr internally reaches
# Network.Socket.Data.parseIPv4's `Cast String Integer` usage, and the
# reference install's generated C calls `idris2_cast_string_to_Integer`
# (lowercase) where only `idris2_cast_String_to_Integer` (capital S) is
# actually defined, an implicit-declaration/int-to-pointer compile
# error confirmed by a direct `idris2 --cg refc` attempt. rc2's own
# codegen has no equivalent naming inconsistency and compiles this test
# cleanly. `.expected` here is rc2's own manually-verified-correct
# output (deterministic bind/listen/connect/send/recv transcript over a
# 127.0.0.1 loopback), saved by hand -- same reasoning as
# Test7CastMatrix/Test17ConstFold above, there is no real-RefC output
# to diff against in the first place.
#
# Test42SupportMisc: exercises setEnv/unsetEnv, which real `idris2 --cg
# refc` cannot even compile -- upstream's own idris_support.h declares
# no prototype for idris2_setenv/idris2_unsetenv (idris_support.c
# defines both; System.idr's own %foreign targets them through that
# same header regardless), and unlike rc2 (which now declares them
# itself in idris2rc2_runtime.h, ahead of that #include, so its own
# build never sees the mismatch -- see that file's own comment) real
# RefC's build has no such workaround: gcc's implicit-declaration
# warning is treated as a hard error in this project's own reference
# toolchain, confirmed by direct `idris2 --cg refc` attempt. Not
# RefC/rc2-specific -- a genuine upstream defect this project works
# around for its own tests but can't fix. `.expected` here is rc2's own
# manually-verified-correct output, same reasoning as
# Test7CastMatrix/Test17ConstFold above.
NO_REFC_DIFF_TESTS="Test7CastMatrix Test17ConstFold Test24CStructSupport Test26GCPtrAliasString Test28Utf8Strings Test29GCAnyPtrReturn Test31CgExtraRuntime Test32CgInlineRuntime Test35NetworkLoopback Test42SupportMisc"

# Leak-sensitive by design (reference-counting/reuse/native-shadow
# regression tests) -- checked with valgrind by default even without
# --valgrind-all.
LEAK_SENSITIVE_TESTS="Test1Basics Test9SelfTailLoop Test10MutualLoop Test11DualABILeak Test12ConAltNative Test13NativeArgChain Test14SmallFunctionInline Test15CompareFusionThroughCall Test16LoopContinuePostDrop Test18ClosureInPlaceGrow Test19LoopInvariantParam Test20LoopInvariantExpr Test21BoxedInvariantNotHoisted Test22BranchSinking Test23SinkPastSelfDrop Test24CStructSupport Test25ConstConFold Test26GCPtrAliasString Test27FFIDualABI Test28Utf8Strings Test29GCAnyPtrReturn Test33WideDualABIWorker Test34WideClosureDispatch Test35NetworkLoopback Test36ReuseOfferUniqueLeak Test37SystemDirectory Test40SystemProcess Test41FFIMalloc Test42SupportMisc Test43FileExtra Test44IORefExtPrimLeak Test45ArrayExtPrimLeak Test46FastPackUnconditional"

# KNOWN-BUGS.md's own remaining pre-existing leaks -- "definitely
# lost" byte count, exactly. Anything else non-zero is a genuine new
# failure. (Test9SelfTailLoop's own former 784-byte entry was
# root-caused and fixed -- RLoopContinue's own missing postDrop field,
# see KNOWN-BUGS.md -- and is expected to be clean now.)
#
# Test28Utf8Strings/Test35NetworkLoopback/Test40SystemProcess used to
# have entries here for the fastPack/fastConcat leak (Test28's own
# `pack` calls; Test35's via `Network.Socket.Data.parseIPv4`; Test40's
# via `System.File.ReadWrite`'s `fRead'`, the latter two originating
# inside the pre-compiled `network`/`base` packages' own already-
# elaborated code). All three are genuinely clean (0 bytes) now, not
# just KNOWN: Compiler.RC2.Emit's own `createCFunctions` intercepts
# `Prelude.Types.fastPack`/`fastConcat` by full name+signature at
# C-emission time and redirects to rc2's own leak-free
# `fastPackFixed`/`fastConcatFixed` unconditionally, project-wide --
# reaching every call site regardless of which package it originates
# from, unlike the retired `Prelude.Fix.RC2` module's own `%transform`,
# which could only ever rewrite a call site within its own importer's
# elaboration scope. See KNOWN-BUGS.md / rc2/doc/fastpack-fix.md for
# the full writeup. Test46FastPackUnconditional is this fix's own
# dedicated regression test (no opt-in import at all, unlike the
# retired module).
#
# Test1Basics no longer needs an entry here either: its own 40-byte leak
# (KNOWN-BUGS.md's prior attribution to fastPack/fastConcat was wrong --
# it was actually the RExtPrim ownership-annotation gap, see
# doc/c-struct-support.md's own addendum) is genuinely fixed now, not
# just reclassified.
declare -A KNOWN_LEAK_BYTES=( )

is_in() { local x; for x in $2; do [ "$x" = "$1" ] && return 0; done; return 1; }

ALL_TESTS="$(cd "$RC2_DIR/tests" && ls Test*.idr | sed 's/\.idr$//' | sort)"

for name in $ALL_TESTS; do
    compile_t0="$(date +%s.%N)"
    # A companion C file ($name.c) supplies the actual C-side
    # implementation a %foreign declaration needs (e.g. a struct
    # constructor/destructor establishing a struct name for
    # getField/setField -- see rc2/doc/c-struct-support.md). Compiled
    # once here and linked in via IDRIS2_CFLAGS/IDRIS2_LDFLAGS, the
    # same environment variables Compiler.RC2.CC's own
    # findCFlags/findLDFlags already read -- most tests have no such
    # file, so this is a no-op for them. Reused below for the real
    # `idris2 --cg refc` --regen-expected invocation too, not just
    # rc2's own -- a companion-C test with nothing else disqualifying
    # it from NO_REFC_DIFF_TESTS still needs the same header/object
    # available to compile against the real reference compiler.
    companion_env=()
    if [ -f "$RC2_DIR/tests/$name.c" ]; then
        nix-shell -p gcc --run "gcc -c $RC2_DIR/tests/$name.c -o $TMP/${name}_companion.o" \
            > "$TMP/${name}_companion_compile.log" 2>&1
        if [ $? -ne 0 ]; then
            report_fail "$name" "companion C file failed to compile, see $TMP/${name}_companion_compile.log"
            continue
        fi
        companion_env=("IDRIS2_LDFLAGS=$TMP/${name}_companion.o" "IDRIS2_CFLAGS=-I$RC2_DIR/tests")
    fi
    env "${companion_env[@]}" nix-shell -p idris2 gcc gmp pkg-config --run \
        "$IDRIS2RC2 --cg rc2 -p network -p linear -p rc2base --directive dumprcexpr$extra_directive_args $RC2_DIR/tests/$name.idr -o $TMP/${name}_rc2" \
        > "$TMP/${name}_compile.log" 2>&1
    compile_time="$(elapsed "$compile_t0" "$(date +%s.%N)")"
    if [ ! -x "$TMP/${name}_rc2" ]; then
        report_fail "$name" "rc2 compile error (compile ${compile_time}s), see $TMP/${name}_compile.log"
        continue
    fi

    # Test30CgPragma's own `%cg rc2 dumpdualabi` source pragma is the
    # ONLY thing that can produce this build's `.dualabi` dump file --
    # this compile never got `--directive dumpdualabi` on the CLI (only
    # the baked-in `--directive dumprcexpr` above, plus whatever
    # --directive flags this verify.sh run was given by hand, none of
    # which are dumpdualabi by default). Confirms Compiler.RC2.RC2's
    # `getDirectives (Other "rc2")` wiring actually picks up source-level
    # %cg rc2 directives, not just CLI ones.
    if [ "$name" = "Test30CgPragma" ]; then
        if [ -f "$TMP/${name}_rc2.dualabi" ]; then
            report_pass "$name (source %cg rc2 dumpdualabi honored -- $TMP/${name}_rc2.dualabi produced with no CLI --directive dumpdualabi)"
        else
            report_fail "$name" "source %cg rc2 dumpdualabi NOT honored -- $TMP/${name}_rc2.dualabi missing"
        fi
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
            env "${companion_env[@]}" nix-shell -p idris2 gcc gmp pkg-config --run \
                "idris2 --cg refc -p network -p linear -p rc2base $RC2_DIR/tests/$name.idr -o $TMP/${name}_refc" \
                > "$TMP/${name}_refc_compile.log" 2>&1
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

    # Each valgrind run is its own single-threaded process operating on
    # its own binary/log file, so the leak-sensitive subset (or the
    # full suite under --valgrind-all) parallelizes cleanly. Capped at
    # nproc/2 rather than nproc: valgrind's own per-process memory
    # overhead (multiple times the target binary's) means running one
    # per core risks swapping on a memory-constrained machine, which
    # would erase the wall-clock win this is for. Override via
    # VALGRIND_JOBS= if a given machine can take more (or needs less).
    valgrind_jobs="${VALGRIND_JOBS:-$(( $(nproc) / 2 > 0 ? $(nproc) / 2 : 1 ))}"

    valgrind_names=()
    for name in $ALL_TESTS; do
        if [ "$VALGRIND_ALL" -eq 0 ] && ! is_in "$name" "$LEAK_SENSITIVE_TESTS"; then
            continue
        fi
        [ -x "$TMP/${name}_rc2" ] || continue
        valgrind_names+=("$name")
    done

    valgrind_t0="$(date +%s.%N)"
    running=0
    for name in "${valgrind_names[@]}"; do
        nix-shell -p valgrind --run \
            "valgrind --leak-check=full --error-exitcode=1 $TMP/${name}_rc2" \
            > "$TMP/${name}_valgrind.log" 2>&1 &
        running=$((running + 1))
        if [ "$running" -ge "$valgrind_jobs" ]; then
            wait -n
            running=$((running - 1))
        fi
    done
    wait
    valgrind_time="$(elapsed "$valgrind_t0" "$(date +%s.%N)")"

    # Reporting stays a separate, sequential pass over valgrind_names
    # (not folded into the launch loop above) so PASS/KNOWN/FAIL lines
    # print in the same deterministic $ALL_TESTS order regardless of
    # which background job happened to finish first.
    for name in "${valgrind_names[@]}"; do
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
    echo "(valgrind phase: ${valgrind_time}s wall, ${#valgrind_names[@]} tests, $valgrind_jobs parallel jobs)"
fi

echo
echo "== $pass passed, $known known (pre-existing, see KNOWN-BUGS.md), $fail failed =="
if [ "$fail" -gt 0 ] || [ "$refc_suite_status" -ne 0 ]; then
    [ "${#failed_names[@]}" -gt 0 ] && echo "Failed: ${failed_names[*]}"
    exit 1
fi
exit 0
