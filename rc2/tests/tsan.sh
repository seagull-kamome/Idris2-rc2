#!/usr/bin/env bash
# ThreadSanitizer pass over the tests that run Idris code on several
# threads (rc2/doc/hybrid-refcount.md, "Tests"). Called by verify.sh as
# its last phase; also runs on its own:
#
#   cd rc2/tests
#   nix-shell -p gcc gmp pkg-config --run ./tsan.sh
#
# It builds its own copies of the rc2 runtime (rc2/support/rc2) and of
# rc2base's C support with -fsanitize=thread under build/tsan/, compiles
# each program below with rc2/build/exec/idris2-rc2, links them
# together, and runs each TSAN_RUNS times (default 3). Thread
# interleavings differ from run to run, so a race may show up in only
# some of them. Any "WARNING: ThreadSanitizer" is a FAIL; the reports
# are kept in build/tsan/<name>.<run>.log.
#
# Prints PASS/FAIL lines like verify.sh; exits non-zero on any FAIL.
# Expects idris2-rc2 already built and rc2base installed (verify.sh's
# own prerequisites).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RC2_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$RC2_DIR/.." && pwd)"
IDRIS2RC2="$RC2_DIR/build/exec/idris2-rc2"
RUNS="${TSAN_RUNS:-3}"

# shellcheck source=/dev/null
source "$REPO_DIR/env.sh"

PREFIX="$(idris2 --prefix)/idris2-0.8.0"
OUT="$SCRIPT_DIR/build/tsan"
TSAN_CFLAGS="-O1 -g -fsanitize=thread"

# name|source file
PROGRAMS=(
    "Test102MultiThreadSwitch|$SCRIPT_DIR/Test102MultiThreadSwitch/Test102MultiThreadSwitch.idr"
    "Test104ThreadStress|$SCRIPT_DIR/Test104ThreadStress/Test104ThreadStress.idr"
    "TestConcurrency|$REPO_DIR/libs/rc2base/tests/TestConcurrency.idr"
    "TestMVar|$REPO_DIR/libs/rc2base/tests/TestMVar.idr"
    "TestMultiThreadRC2|$REPO_DIR/libs/rc2base/tests/TestMultiThreadRC2.idr"
)

fails=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1${2:+ ($2)}"; fails=$((fails + 1)); }

rm -rf "$OUT"
mkdir -p "$OUT/rt" "$OUT/base"

cp "$RC2_DIR"/support/rc2/*.[ch] "$RC2_DIR"/support/rc2/Makefile "$OUT/rt/"
if ! make -C "$OUT/rt" CFLAGS="$TSAN_CFLAGS -Wall -Wno-unused-function" > "$OUT/rt.log" 2>&1; then
    fail "tsan runtime build" "see $OUT/rt.log"
    exit 1
fi

# rc2base's own Makefile, with CFLAGS replaced so it picks up the TSan
# runtime's headers.
cp "$REPO_DIR"/libs/rc2base/support/c/* "$OUT/base/"
if ! make -C "$OUT/base" libidris2rc2base.a \
        CFLAGS="$TSAN_CFLAGS -fPIC -w -I$OUT/rt -I$PREFIX/support/c -I." > "$OUT/base.log" 2>&1; then
    fail "tsan rc2base build" "see $OUT/base.log"
    exit 1
fi

for p in "${PROGRAMS[@]}"; do
    name="${p%%|*}"; src="${p#*|}"
    work="$OUT/$name"
    mkdir -p "$work"
    cp "$src" "$work/"
    if ! (cd "$work" && "$IDRIS2RC2" --cg rc2 -p rc2base "$(basename "$src")" -o "$name") > "$work/rc2.log" 2>&1; then
        fail "$name (tsan)" "rc2 build failed, see $work/rc2.log"
        continue
    fi
    if ! { gcc $TSAN_CFLAGS -w -c "$work/build/exec/$name.c" -o "$work/$name.o" \
               -I"$OUT/rt" -I"$PREFIX/support/c" -I"$REPO_DIR/libs/rc2base/support/c" &&
           gcc -fsanitize=thread "$work/$name.o" "$OUT/base/libidris2rc2base.a" -o "$work/$name" \
               -L"$OUT/rt" -lidris2rc2 "$PREFIX/lib/libidris2_support.a" -lgmp -lm -lpthread; } \
            > "$work/cc.log" 2>&1; then
        fail "$name (tsan)" "C build failed, see $work/cc.log"
        continue
    fi
    warnings=0
    for run in $(seq 1 "$RUNS"); do
        # TSan's shadow memory needs a fixed address layout; newer kernels
        # randomise too much of it otherwise.
        # Ten times verify.sh's TEST_TIMEOUT: TSan slows a program down a lot.
        timeout --kill-after=5 "$((${TEST_TIMEOUT:-60} * 10))" \
            setarch -R "$work/$name" > /dev/null 2> "$OUT/$name.$run.log"
        case $? in
            124|137) echo "timed out after $((${TEST_TIMEOUT:-60} * 10))s (TEST_TIMEOUT)" >> "$OUT/$name.$run.log"
                     warnings=$((warnings + 1)) ;;
        esac
        n="$(grep -c 'WARNING: ThreadSanitizer' "$OUT/$name.$run.log")"
        warnings=$((warnings + n))
    done
    if [ "$warnings" -eq 0 ]; then
        pass "$name (tsan, $RUNS runs)"
    else
        fail "$name (tsan)" "$warnings warning(s) over $RUNS runs, see $OUT/$name.*.log"
    fi
done

[ "$fails" -eq 0 ]
