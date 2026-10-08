#!/usr/bin/env bash
# One-shot correctness verification for tools/rcexpr-lint: builds
# the CLI against rc2base+contrib (plain Chez backend -- this tool
# never needs to run *through* rc2 itself, it only reads text files),
# then runs it over the hand-written `.rcexpr` fixtures and checks
# both the exit code and the exact report (anomalies and metrics)
# against the fixture's own `.expected` file. `clean.rcexpr`/`anomalies.rcexpr` cover the
# ownership check itself (Lint.idr's own module note has the full rule list);
# `dupcount.rcexpr` is a narrow regression test for a real bug this
# tool's own parser had (`dup vN xM`'s count glued onto `x` as one
# token, silently undercounted if read as two separate ones) -- see
# `Language.RCExpr.Parser.dupG`'s own doc comment.
# `metrics.rcexpr` holds every node kind `Metrics.idr` counts, so each
# figure is checked against a hand count at least once.
# `leakclean.rcexpr` holds the balanced shapes the leak check has to
# accept (erased alts, always-unboxed locals, immortal lets, padded loop
# params, struct fields, reuse, FFI/callRep consumption); `leak.rcexpr`
# one definition per leak-check finding. `borrow.rcexpr` is run with
# `--borrow-stats`; every figure in its `.expected` was counted by hand.
# `borrowtail.rcexpr` is run with `--borrow-tail-stats`: one parameter that
# nets positive over tail and non-tail call sites, one that nets negative,
# one blocked by a tail call and another reason; hand-counted too.
# `pushdown.rcexpr` is run with `--pushdown-stats`; each definition is one
# pattern (or a negative case next to it) and every figure was counted by
# hand: the A/B/C1/C2/D/D0 events, the E census and the dup/drop totals.
# `fieldborrow.rcexpr` covers a case-alt field borrowing its
# scrutinee's reference, including the exact shape of a real
# use-after-free (a field read after its scrutinee was dropped).

#
# Usage: ./verify.sh
#
# Requires gcc/gmp/pkg-config on PATH (no nix-shell) and rc2base already built+installed
# (tools/rcexpr-lint depends on it -- see libs/rc2base/tests/
# verify.sh or libs/rc2base/README.md).

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(dirname "$TESTS_DIR")"
REPO_ROOT="$(cd "$TOOL_DIR/../.." && pwd)"

fail() { echo "FAIL  $1"; exit 1; }

source "$REPO_ROOT/env.sh"

echo "=== Build rcexpr-lint ==="
(cd "$TOOL_DIR" && idris2 -p rc2base -p contrib -o rcexpr-lint RcexprLint.idr)

RCEXPR_LINT="$TOOL_DIR/build/exec/rcexpr-lint"
[[ -x "$RCEXPR_LINT" ]] || fail "build did not produce $RCEXPR_LINT"

check() {
    local name="$1" file="$2" want_exit="$3" flag="${4:-}"
    local want_out got_out got_exit
    want_out="$(cat "${file%.rcexpr}.expected")"
    got_out="$("$RCEXPR_LINT" ${flag:+"$flag"} "$file" 2>&1)" && got_exit=0 || got_exit=$?
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

check "clean.rcexpr (no anomalies)" "$TESTS_DIR/clean.rcexpr" 0
check "anomalies.rcexpr (every use-after-free/double-drop check fires)" "$TESTS_DIR/anomalies.rcexpr" 1
check "dupcount.rcexpr (dup vN xM count regression)" "$TESTS_DIR/dupcount.rcexpr" 1
check "metrics.rcexpr (every counted node kind)" "$TESTS_DIR/metrics.rcexpr" 0
check "fieldborrow.rcexpr (fields borrow from their scrutinee)" "$TESTS_DIR/fieldborrow.rcexpr" 1
check "foreigntypes.rcexpr (struct and function types in %foreign signatures)" "$TESTS_DIR/foreigntypes.rcexpr" 0
check "leakclean.rcexpr (balanced shapes the leak check must accept)" "$TESTS_DIR/leakclean.rcexpr" 0
check "typedcase.rcexpr (typed-constant case scrutinees are refcount-free)" "$TESTS_DIR/typedcase.rcexpr" 0
check "leak.rcexpr (every leak-check finding fires)" "$TESTS_DIR/leak.rcexpr" 1
check "borrow.rcexpr (borrow statistics, hand-counted)" "$TESTS_DIR/borrow.rcexpr" 0 --borrow-stats
check "borrowtail.rcexpr (tail-blocked parameters, hand-counted)" "$TESTS_DIR/borrowtail.rcexpr" 0 --borrow-tail-stats
check "pushdown.rcexpr (push-down statistics, hand-counted)" "$TESTS_DIR/pushdown.rcexpr" 0 --pushdown-stats

echo "=== All rcexpr-lint checks passed ==="
