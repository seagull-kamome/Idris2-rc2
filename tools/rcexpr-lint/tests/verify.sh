#!/usr/bin/env bash
# One-shot correctness verification for tools/rcexpr-lint: builds
# the CLI against rc2base+contrib (plain Chez backend -- this tool
# never needs to run *through* rc2 itself, it only reads text files),
# then runs it over five hand-written `.rcexpr` fixtures and checks
# both the exit code and the exact report (anomalies and metrics)
# against what's expected. `clean.rcexpr`/`anomalies.rcexpr` cover the
# ownership check itself (Lint.idr's own module note has the full rule list);
# `dupcount.rcexpr` is a narrow regression test for a real bug this
# tool's own parser had (`dup vN xM`'s count glued onto `x` as one
# token, silently undercounted if read as two separate ones) -- see
# `Language.RCExpr.Parser.dupG`'s own doc comment.
# `metrics.rcexpr` holds every node kind `Metrics.idr` counts, so each
# figure is checked against a hand count at least once.
# `fieldborrow.rcexpr` covers a case-alt field borrowing its
# scrutinee's reference, including the exact shape of a real
# use-after-free (a field read after its scrutinee was dropped).

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
"rcexpr-lint: clean.rcexpr: 4 defs, no anomalies found
metrics (places in the IR, not executions):
  definitions        4  (functions 4, workers 0, constructors 0, foreign 0, error 0)
  con                0  (fresh 0, reusing a cell 0)
  partial            0  (closures built)
  apply              0  (closure calls)
  call               0  (plain 0, callRep 0, FFI inline 0)
  op                 2  (op 2, extprim 0)
  let                1  (Boxed 1, native 0)
  case               1  (constructor 0, constant 0, cmp 1)
  dup                1  (increments, in 1 dup nodes)
  drop               4  (decrements, in 4 drop nodes)
  postDrop           3  (decrements attached to another node: postDrop, dropOnUnique, prologueDrop)
  free               0
  reuseOffer         0  (releaseReuse 0)
  loop               0  (continue 0)
  memoize            0
  crash              0"

check "anomalies.rcexpr (every check fires)" "$TESTS_DIR/anomalies.rcexpr" 1 \
"anomalies.rcexpr: TestUseAfterFree: v1 use-after-free (RV)
anomalies.rcexpr: TestDoubleDrop: v1 double-drop (drop)
anomalies.rcexpr: TestDoubleDrop: v1 use-after-free (RV)
anomalies.rcexpr: TestBranchUseAfterFree: v1 use-after-free (RV)
anomalies.rcexpr: TestPostDropUseAfterFree: v1 use-after-free (op args)
rcexpr-lint: 5 anomalies found
metrics (places in the IR, not executions):
  definitions        4  (functions 4, workers 0, constructors 0, foreign 0, error 0)
  con                0  (fresh 0, reusing a cell 0)
  partial            0  (closures built)
  apply              0  (closure calls)
  call               0  (plain 0, callRep 0, FFI inline 0)
  op                 2  (op 2, extprim 0)
  let                1  (Boxed 1, native 0)
  case               1  (constructor 0, constant 0, cmp 1)
  dup                0  (increments, in 0 dup nodes)
  drop               4  (decrements, in 4 drop nodes)
  postDrop           2  (decrements attached to another node: postDrop, dropOnUnique, prologueDrop)
  free               0
  reuseOffer         0  (releaseReuse 0)
  loop               0  (continue 0)
  memoize            0
  crash              0"

check "dupcount.rcexpr (dup vN xM count regression)" "$TESTS_DIR/dupcount.rcexpr" 1 \
"dupcount.rcexpr: TestDupCountRegression: v1 use-after-free (RV)
rcexpr-lint: 1 anomalies found
metrics (places in the IR, not executions):
  definitions        1  (functions 1, workers 0, constructors 0, foreign 0, error 0)
  con                0  (fresh 0, reusing a cell 0)
  partial            0  (closures built)
  apply              0  (closure calls)
  call               0  (plain 0, callRep 0, FFI inline 0)
  op                 0  (op 0, extprim 0)
  let                0  (Boxed 0, native 0)
  case               0  (constructor 0, constant 0, cmp 0)
  dup                2  (increments, in 1 dup nodes)
  drop               3  (decrements, in 3 drop nodes)
  postDrop           0  (decrements attached to another node: postDrop, dropOnUnique, prologueDrop)
  free               0
  reuseOffer         0  (releaseReuse 0)
  loop               0  (continue 0)
  memoize            0
  crash              0"

check "metrics.rcexpr (every counted node kind)" "$TESTS_DIR/metrics.rcexpr" 0 \
"rcexpr-lint: metrics.rcexpr: 6 defs, no anomalies found
metrics (places in the IR, not executions):
  definitions        6  (functions 3, workers 1, constructors 1, foreign 1, error 0)
  con                2  (fresh 1, reusing a cell 1)
  partial            1  (closures built)
  apply              1  (closure calls)
  call               5  (plain 3, callRep 1, FFI inline 1)
  op                 2  (op 1, extprim 1)
  let                9  (Boxed 7, native 2)
  case               2  (constructor 1, constant 1, cmp 0)
  dup                2  (increments, in 1 dup nodes)
  drop               2  (decrements, in 2 drop nodes)
  postDrop           2  (decrements attached to another node: postDrop, dropOnUnique, prologueDrop)
  free               1
  reuseOffer         1  (releaseReuse 1)
  loop               1  (continue 1)
  memoize            1
  crash              1"

check "fieldborrow.rcexpr (fields borrow from their scrutinee)" "$TESTS_DIR/fieldborrow.rcexpr" 1 \
"fieldborrow.rcexpr: TestFieldReadAfterScrutineeDrop: v2 use-after-free (dup)
fieldborrow.rcexpr: TestFieldReadAfterScrutineeDrop: v3 use-after-free (con args)
fieldborrow.rcexpr: TestFieldReadAfterScrutineeDrop: v4 use-after-free (con args)
fieldborrow.rcexpr: TestNestedFieldAfterOuterDrop: v3 use-after-free (RV)
fieldborrow.rcexpr: TestDropOfBorrowedField: v2 double-drop (drop)
rcexpr-lint: 5 anomalies found
metrics (places in the IR, not executions):
  definitions        5  (functions 5, workers 0, constructors 0, foreign 0, error 0)
  con                1  (fresh 1, reusing a cell 0)
  partial            0  (closures built)
  apply              0  (closure calls)
  call               0  (plain 0, callRep 0, FFI inline 0)
  op                 0  (op 0, extprim 0)
  let                1  (Boxed 1, native 0)
  case               6  (constructor 6, constant 0, cmp 0)
  dup                3  (increments, in 3 dup nodes)
  drop               4  (decrements, in 4 drop nodes)
  postDrop           1  (decrements attached to another node: postDrop, dropOnUnique, prologueDrop)
  free               0
  reuseOffer         1  (releaseReuse 1)
  loop               0  (continue 0)
  memoize            0
  crash              0"

echo "=== All rcexpr-lint checks passed ==="
