#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

# InlineCalleeFirst: Criterion A, callee first (rc2/doc/inlining.md):
# whatever is inlined leaves neither a call nor, with dead code gone, a
# definition.
dump="$TMP/${name}_rc2.rcexpr"
m="Test114Inline[._]InlineCalleeFirst"
left="$(grep -cE "(call|callRep|def).*${m}[._](f|g|h|piece|leqInt|leqNat)[^A-Za-z0-9_]|_Eq_Ordering" "$dump" || true)"
if [ "$left" = "0" ]; then
    pass "chain f -> g -> h, piece and the compare-based <= all inlined: no call or definition left"
else
    fail "$left call/def line(s) to f, g, h, piece, leqInt, leqNat or an Ordering (==) remain in $dump"
fi
# Never inlined: a self-recursive function, and one whose rewritten body
# is over the threshold although each piece of it is small.
selfCalls="$(grep -cE "call.*${m}[._]selfRec" "$dump" || true)"
bigCalls="$(grep -cE "call.*${m}[._]big[^A-Za-z]" "$dump" || true)"
if [ "$selfCalls" -ge 1 ] && [ "$bigCalls" -ge 2 ]; then
    pass "selfRec ($selfCalls calls) and the over-threshold big ($bigCalls calls) stay calls"
else
    fail "selfRec calls $selfCalls (want >=1), big calls $bigCalls (want >=2) in $dump"
fi
