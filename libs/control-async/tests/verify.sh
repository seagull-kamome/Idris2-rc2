#!/usr/bin/env bash
# One-shot correctness verification for libs/control-async: type-checks the
# package against the plain Chez backend, installs it into the *same* shared install/
# prefix rc2 itself uses (never a separate throwaway prefix -- a
# second, parallel install of this same package was found to go stale
# independently of the shared one, since nothing ever re-syncs the
# two, and its own package resolution could end up picking either one
# depending on search-path order; installing to the one shared
# location rc2's own env.sh already defaults to removes that
# ambiguity entirely), then builds every test under tests/<TestName>/
# (one directory per test, holding <TestName>.idr and
# <TestName>.expected) against idris2-rc-cg's own rc2 backend, runs it
# and diffs its stdout against <TestName>.expected. The TESTS list
# below is explicit; the script fails if it and the tests/*/
# directories disagree. Small-scale sibling of
# rc2/tests/verify.sh -- see that script's own header for the fuller
# rationale this one deliberately doesn't repeat.
#
# Usage: ./verify.sh
#
# Requires gcc, gmp, pkg-config and make on PATH (the same way
# rc2/tests/verify.sh does -- idris2 itself is the self-built one,
# never nixpkgs', per AGENT.md's "Policy: don't use nixpkgs' idris2 for
# rc2 work") and rc2/build/exec/idris2-rc2 already built (see rc2/tests/verify.sh or
# rc2/README.md).

set -euo pipefail

# rc2's runtime does setlocale(LC_ALL, "") in idris2rc2_rtInit, so a
# compiled test's behaviour follows this shell's locale; pin it
# (rc2/doc/runtime-lifecycle.md).
export LC_ALL=C.UTF-8

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(dirname "$TESTS_DIR")"
REPO_ROOT="$(dirname "$(dirname "$PKG_DIR")")"
IDRIS2RC2="$REPO_ROOT/rc2/build/exec/idris2-rc2"
TMP="$(mktemp -d)"
trap 'exec 3>&- 2>/dev/null; rm -rf "$TMP"' EXIT

fail() { echo "FAIL  $1"; exit 1; }

# Create a FIFO for stdin that stays open but is empty (prevents tests from
# hanging on stdin reads). Tests that need stdin can write to /dev/fd/3.
mkfifo "$TMP/stdin"
exec 3<>"$TMP/stdin"

if [[ ! -x "$IDRIS2RC2" ]]; then
    fail "rc2/build/exec/idris2-rc2 not found -- build it first (see rc2/tests/verify.sh)"
fi

source "$REPO_ROOT/env.sh"

# name|extra -p packages (control-async and rc2base are always passed)|what the test covers
TESTS=(
    "TestTaskEnv||Control.Task: Env.slot (one value per scheduler, released at close) and Env.addSource (taken out when given up)"
    "TestTaskIdle||Control.Task.Scheduler.turn: once every task has ended and turn says nothing is left, pollFd is not readable (no busy loop in a program that waits for it)"
    "TestTaskPointThen||Control.Task: a chain of liftIO runs on one worker in parallel mode (same results and order everywhere, a long chain, a mixed one, a loop that is given up)"
    "TestTaskHandoff||Control.Task: handoff gives back a value whose task is cancelled; finally and spawnOwning run their action once"
    "TestNetworkAsync|network contrib|Network.Async: serve a connection; a lost race closes the listener and a just-accepted connection; recv/send refuse bad ranges"
    "TestTaskUring||Control.Task.Uring: nop, file round trip, two requests at once, a read woken by a write, a request given up by a race"
    "TestTaskNoUring||Control.Task.Uring imported and not used: builds without liburing, no liburing in the generated C"
    "TestTask||Control.Task: monad, both/race/spawn, cancellation, timers, epoll source, inbox"
    "TestTaskChan||Control.Task.Chan: producer and consumers on four threads, close, full/closed/drained, waits given up"
    "TestTaskMVar||Control.Task.MVar: lock between tasks on four threads, waits, the line, waits and modifications given up"
    "TestTaskRef||Control.Task.Ref: no update lost with actions on four threads, each ticket handed out once"
)

# Tests that need liburing's headers (liburing.h); skipped the same way.
NEEDS_URING=" TestTaskUring "
# Tests built with IDRIS2_CFLAGS=-D_GNU_SOURCE (declarations glibc hides otherwise).
NEEDS_GNU_SOURCE=" TestTask TestTaskUring "
# Tests whose generated C must not mention liburing at all.
NO_LIBURING_C=" TestTaskNoUring "
have_uring_h() { echo '#include <liburing.h>' | gcc -E -x c - > /dev/null 2>&1; }

echo "=== Check TESTS against the tests/*/ directories ==="
# Every tests/<T>/ must be listed and have <T>.idr + <T>.expected, and
# every listed test must have its directory.
listed=()
for entry in "${TESTS[@]}"; do listed+=("${entry%%|*}"); done
for d in "$TESTS_DIR"/*/; do
    t="$(basename "$d")"
    [[ "$t" == build ]] && continue
    found=0
    for l in "${listed[@]}"; do [[ "$l" == "$t" ]] && found=1; done
    [[ $found -eq 1 ]] || fail "tests/$t/ is not in the TESTS list"
done
for t in "${listed[@]}"; do
    [[ -d "$TESTS_DIR/$t" ]] || fail "TESTS lists $t but tests/$t/ does not exist"
    [[ -f "$TESTS_DIR/$t/$t.idr" ]] || fail "tests/$t/$t.idr missing"
    [[ -f "$TESTS_DIR/$t/$t.expected" ]] || fail "tests/$t/$t.expected missing"
done

echo "=== Check that only Control.Task.Uring imports System.Linux.Uring ==="
# A module of Control.Task that reached liburing would make every program
# that uses tasks need it. (rc2 drops the %foreign declarations that nothing
# reaches, so importing it is harmless; referring to it is not.)
importers="$(grep -rl --include=*.idr -E '^import +(public +)?System\.Linux\.Uring' "$PKG_DIR/src" | sed "s|$PKG_DIR/src/||" | sort | tr '\n' ' ')"
[[ "$importers" == "Control/Task/Uring.idr " ]] || fail "System.Linux.Uring is imported by: $importers (expected only Control/Task/Uring.idr)"

echo "=== Chez backend: type-check ==="
(cd "$PKG_DIR" && idris2 --build control-async.ipkg)

echo "=== Install into the shared install/ prefix ==="
( cd "$PKG_DIR" && idris2 --install control-async.ipkg )

# No IDRIS2_PACKAGE_PATH export needed: idris2 already searches its
# own installation prefix (install/, the same one just installed into
# above) by default. No IDRIS2_CFLAGS/IDRIS2_LDFLAGS needed either:
# Compiler.RC2.CC's own depPkgLibDirs already adds -I<...>/lib and
# -L<...>/lib for every -p'd package's own installed lib/ -- see libs/rc2base/README.md's
# "Native library install location". idris2-rc2 always writes its -o
# output under <cwd>/build/exec/, so each test is built from inside its
# own directory (tests/<T>/build/ is git-ignored). No extra
# LD_LIBRARY_PATH is needed to run: libidris2_support.so already came
# from env.sh's own LD_LIBRARY_PATH, sourced above.
for entry in "${TESTS[@]}"; do
    IFS='|' read -r t extra desc <<< "$entry"
    if [[ "$NEEDS_URING" == *" $t "* ]] && ! have_uring_h; then
        echo "SKIP  $t -- liburing.h not found by gcc (install liburing's development files)"
        continue
    fi
    pflags=(-p control-async -p rc2base)
    for p in $extra; do pflags+=(-p "$p"); done

    echo "=== rc2 backend: build $t ($desc) ==="
    # idris2-rc2 exits 0 when only the generated C fails to compile; drop
    # the previous binary so that a failed build cannot pass on its output.
    rm -f "$TESTS_DIR/$t/build/exec/${t}_verify"
    gnu_flags=""
    [[ "$NEEDS_GNU_SOURCE" == *" $t "* ]] && gnu_flags="-D_GNU_SOURCE"
    ( cd "$TESTS_DIR/$t" && ulimit -v 12000000 && IDRIS2_CFLAGS="${IDRIS2_CFLAGS:-} $gnu_flags" timeout 600 \
        "$IDRIS2RC2" --cg rc2 "${pflags[@]}" -o "${t}_verify" "$t.idr" )

    if [[ "$NO_LIBURING_C" == *" $t "* ]] && grep -q liburing "$TESTS_DIR/$t/build/exec/${t}_verify.c"; then
        fail "$t -- liburing appears in the generated C"
    fi

    echo "=== Run and diff against $t.expected ==="
    rc=0
    ( ulimit -v 4000000; timeout 20 "$TESTS_DIR/$t/build/exec/${t}_verify" <&3 ) > "$TMP/actual.out" 2>&1 || rc=$?
    if [[ $rc -ne 0 ]]; then
        cat "$TMP/actual.out"
        fail "$t -- exited with status $rc (124 = 20s timeout)"
    fi

    if diff -u "$TESTS_DIR/$t/$t.expected" "$TMP/actual.out"; then
        echo "PASS  $t"
    else
        fail "$t -- output mismatch (see diff above)"
    fi
done
