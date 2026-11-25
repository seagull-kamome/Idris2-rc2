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

# CompareFusionThroughCall: the Integer variant (`stepI`/`loopI`) fuses
# too, as a `cmp` over Boxed operands -- no `op <=Integer`/`op ==Integer`
# let left, and no call to the `Ord Integer`/`Eq Integer` methods.
dump="$TMP/${name}_rc2.rcexpr"
m="Test114Inline[._]CompareFusionThroughCall"
body="$(awk -v m="$m" '/^def / { on = ($0 ~ m "[._](stepI|loopI)") } on' "$dump")"
cmpsI="$(printf '%s\n' "$body" | grep -cE '^ *cmp (<=|==)Integer ' || true)"
opsI="$(printf '%s\n' "$body" | grep -cE '^ *op (<=|==)Integer ' || true)"
if [ "$cmpsI" -ge 2 ] && [ "$opsI" = "0" ]; then
    pass "Integer compare through a call -- $cmpsI cmp node(s) over Boxed operands, no unfused op"
else
    fail "stepI/loopI: $cmpsI cmp node(s) (want >=2), $opsI unfused op(s) in $dump"
fi

# FunDedup (rc2/doc/fun-dedup.md): sumA/sumB are the same loop under two
# names, wrapA/wrapB the same wrapper once the loops are merged (a second
# round); exactly one of the loops survives, and lastOne (another
# constant, inlined into its caller) keeps its own `* 4`. `--directive nofundedup` makes this FAIL by design.
fd="Test114Inline[._]FunDedup[._]"
sums="$(grep -cE "^def .*${fd}sum[AB][ :]" "$dump" || true)"
wraps="$(grep -cE "^def .*${fd}wrap[AB][ :]" "$dump" || true)"
lasts="$(grep -cE "^ *op \*Int \[.*#4\]" "$dump" || true)"
if [ "$sums" = "1" ] && [ "$wraps" -le 1 ] && [ "$lasts" -ge 1 ]; then
    pass "FunDedup: one of sumA/sumB ($sums), at most one of wrapA/wrapB ($wraps), lastOne's own loop kept"
else
    fail "FunDedup: sumA/sumB defs $sums (want 1), wrapA/wrapB defs $wraps (want <=1), lastOne's *4 ops $lasts (want >=1) in $dump"
fi

# ConstFields (rc2/doc/dead-fields.md, "Constant constructors"): the `Ord Key`
# dictionary reaches Data.SortedMap as one constant whose `max`/`min` fields
# no alt binds, so their closures become `[erased]` and the functions (the
# only ones adding 7 and 9) are gone. `--directive noconstfields` makes this
# FAIL by design.
maxmin="$(grep -cE '^ *op \+Int \[v[0-9]+, #(7|9)\]' "$dump" || true)"
erasedOrd="$(grep -cE '#Prelude\.EqOrd\.MkOrd@Just 0\(.*\[erased\]' "$dump" || true)"
if [ "$maxmin" = "0" ] && [ "$erasedOrd" -ge 1 ]; then
    pass "ConstFields: max/min of Ord Key dropped, the dictionary holds [erased] fields"
else
    fail "ConstFields: $maxmin max/min op(s) left (want 0), $erasedOrd Ord constant(s) with [erased] fields (want >=1) in $dump"
fi

# ShareSubtrees (rc2/doc/shared-subtrees.md): `pairUp`'s last clause, which
# the case tree holds once for each alt of its first `case` that misses, is
# one function, called from each of those places: its one string literal
# is in the program once. `--directive nosharesubtrees` makes this FAIL by
# design.
# `score`'s three alts compute alike over a different field each: one
# function, called with that field (its constant 4099 once).
shareDefs="$(grep -cE '^def .*rc2_share_Test114Inline_ShareSubtrees' "$dump" || true)"
mixed="$(grep -c '#"mixed "' "$dump" || true)"
k4099="$(grep -c '#4099\]' "$dump" || true)"
if [ "$shareDefs" -ge 1 ] && [ "$mixed" = "1" ] && [ "$k4099" = "1" ]; then
    pass "ShareSubtrees: pairUp's fallback clause and score's alts each written once"
else
    fail "ShareSubtrees: $shareDefs pairUp share(s) (want >=1), the fallback written $mixed time(s) (want 1), score's body $k4099 time(s) (want 1) in $dump"
fi
# WideCall: a function of 24 arguments is called with them one by one, not
# as one array through a closure and the trampoline (`MaxExtractFunArgs`,
# 32), directly and as a closure's function.
c="$TMP/${name}_rc2.c"
arrays="$(grep -cE 'Test114Inline_WideCall_wide[A-Za-z0-9_]*\(IDRIS2RC2_Value \*var_arglist' "$c" || true)"
direct="$(grep -cE 'Test114Inline_WideCall_wide\(idris2rc2_mkInt64' "$c" || true)"
if [ "$arrays" = "0" ] && [ "$direct" -ge 1 ]; then
    pass "WideCall: wide takes its 24 arguments one by one, $direct direct call(s)"
else
    fail "WideCall: $arrays array-taking definition(s) of wide (want 0), $direct direct call(s) (want >=1) in $c"
fi

