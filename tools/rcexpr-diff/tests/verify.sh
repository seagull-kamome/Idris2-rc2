#!/usr/bin/env bash
# Builds tools/rcexpr-diff (plain Chez backend: it only reads text) and
# checks its report and exit code on two hand-written dumps. a.rcexpr and
# b.rcexpr differ in every way the tool must tell apart: variables
# renumbered only (same), rc2-generated clone counters only (same),
# a lifted lambda's counter (same only with --loose), a real change,
# a definition on one side only, and two clones that normalize to one
# name (paired in order, the second as `#2`).
#
# Usage: ./verify.sh

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(dirname "$TESTS_DIR")"
REPO_ROOT="$(cd "$TOOL_DIR/../.." && pwd)"

fail() { echo "FAIL  $1"; exit 1; }

source "$REPO_ROOT/env.sh"

echo "=== Build rcexpr-diff ==="
(cd "$TOOL_DIR" && idris2 -o rcexpr-diff RcexprDiff.idr)

RCEXPR_DIFF="$TOOL_DIR/build/exec/rcexpr-diff"
[[ -x "$RCEXPR_DIFF" ]] || fail "build did not produce $RCEXPR_DIFF"

check() {
    local name="$1" want_exit="$2" want_out="$3"; shift 3
    local got_out got_exit
    got_out="$(cd "$TESTS_DIR" && "$RCEXPR_DIFF" "$@" 2>&1)" && got_exit=0 || got_exit=$?
    if [[ "$got_exit" != "$want_exit" ]]; then
        echo "$got_out"
        fail "$name -- exit code $got_exit, expected $want_exit"
    fi
    if [[ "$got_out" != "$want_out" ]]; then
        echo "--- got ---"; echo "$got_out"; echo "--- want ---"; echo "$want_out"
        fail "$name -- output mismatch"
    fi
    echo "PASS  $name"
}

check "identical dumps" 0 \
"rcexpr-diff: 8 same, 0 differ, 0 only in A, 0 only in B" \
a.rcexpr a.rcexpr

check "strict" 1 \
"rcexpr-diff: 4 same, 3 differ, 1 only in A, 1 only in B
differ: Main.changed
differ: Main.lifted
differ: {rc2_specClosure_Main_fold:*}#2
only in A: Main.gone
only in B: Main.new" \
a.rcexpr b.rcexpr

check "--loose, --show" 1 \
"rcexpr-diff: 5 same, 2 differ, 1 only in A, 1 only in B
differ: Main.changed
differ: {rc2_specClosure_Main_fold:*}#2
only in A: Main.gone
only in B: Main.new
=== Main.changed
@@ line 2
-   dup v0
=== {rc2_specClosure_Main_fold:*}#2
@@ line 3
-   #1
+   #2" \
--loose --show 2 a.rcexpr b.rcexpr

check "usage" 2 \
"usage: rcexpr-diff [--loose] [--show K] A.rcexpr B.rcexpr" \
a.rcexpr

echo "=== All rcexpr-diff checks passed ==="
