#!/usr/bin/env bash
# One-shot correctness verification for tools/rcexpr-lint: builds
# the CLI against rc2base+contrib (plain Chez backend -- this tool
# never needs to run *through* rc2 itself, it only reads text files),
# then runs it over three hand-written `.rcexpr` fixtures and checks
# both the exit code and the exact anomaly list against what's
# expected. `clean.rcexpr`/`anomalies.rcexpr` cover the ownership
# check itself (Lint.idr's own module note has the full rule list);
# `dupcount.rcexpr` is a narrow regression test for a real bug this
# tool's own parser had (`dup vN xM`'s count glued onto `x` as one
# token, silently undercounted if read as two separate ones) -- see
# `Language.RCExpr.Parser.dupG`'s own doc comment.
#
# Usage: ./verify.sh
#
# Requires nix-shell on PATH and rc2base already built+installed
# (tools/rcexpr-lint depends on it -- see libs/rc2base/tests/
# verify.sh or libs/rc2base/README.md).

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(dirname "$TESTS_DIR")"
REPO_ROOT="$(cd "$TOOL_DIR/../.." && pwd)"

fail() { echo "FAIL  $1"; exit 1; }

source "$REPO_ROOT/env.sh"

echo "=== Build rcexpr-lint ==="
nix-shell -p gcc gmp pkg-config --run \
    "cd '$TOOL_DIR' && idris2 -p rc2base -p contrib -o rcexpr-lint RcexprLint.idr"

RCEXPR_LINT="$TOOL_DIR/build/exec/rcexpr-lint"
[[ -x "$RCEXPR_LINT" ]] || fail "build did not produce $RCEXPR_LINT"

check() {
    local name="$1" file="$2" want_exit="$3" want_out="$4"
    local got_out got_exit
    got_out="$("$RCEXPR_LINT" "$file" 2>&1)" && got_exit=0 || got_exit=$?
    # Strip the fixture's own absolute path so expected output doesn't
    # have to hardcode this checkout's own location.
    got_out="${got_out//$file/$(basename "$file")}"
    if [[ "$got_exit" != "$want_exit" ]]; then
        echo "$got_out"
        fail "$name -- exit code $got_exit, expected $want_exit"
    fi
    if [[ "$got_out" != "$want_out" ]]; then
        echo "--- got ---"
        echo "$got_out"
        echo "--- want ---"
        echo "$want_out"
        fail "$name -- output mismatch (see diff above)"
    fi
    echo "PASS  $name"
}

check "clean.rcexpr (no anomalies)" "$TESTS_DIR/clean.rcexpr" 0 \
"rcexpr-lint: clean.rcexpr: 4 defs, no anomalies found"

check "anomalies.rcexpr (every check fires)" "$TESTS_DIR/anomalies.rcexpr" 1 \
"anomalies.rcexpr: TestUseAfterFree: v1 use-after-free (RV)
anomalies.rcexpr: TestDoubleDrop: v1 double-drop (drop)
anomalies.rcexpr: TestDoubleDrop: v1 use-after-free (RV)
anomalies.rcexpr: TestBranchUseAfterFree: v1 use-after-free (RV)
anomalies.rcexpr: TestPostDropUseAfterFree: v1 use-after-free (op args)
rcexpr-lint: 5 anomalies found"

check "dupcount.rcexpr (dup vN xM count regression)" "$TESTS_DIR/dupcount.rcexpr" 1 \
"dupcount.rcexpr: TestDupCountRegression: v1 use-after-free (RV)
rcexpr-lint: 1 anomalies found"

echo "=== All rcexpr-lint checks passed ==="
