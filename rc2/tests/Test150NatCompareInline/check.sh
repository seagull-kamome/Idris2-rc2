#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
# No Nat comparison calls the 3-way Integer compare any more (rc2/doc/inlining.md,
# "Case of a literal"): before, `<`, `>=`, `>` and `<=` on Nat each became a
# worker that called it.
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

dump="$TMP/${name}_rc2.rcexpr"

calls="$(grep -c 'compare_Ord_Integer' "$dump" || true)"
if [ "$calls" = "0" ]; then
    pass "Nat comparisons: no call to the 3-way Integer compare"
else
    fail "compare_Ord_Integer appears $calls time(s) in $dump"
fi
