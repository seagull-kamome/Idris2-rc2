#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

# `classify`/`describe` regression-check Compiler.RC2.DualABI's
# constant-`case` scrutinee promotion (`constCaseScrutineeNativeReads`,
# see the test's own comment): both workers return a native scalar read
# only as a `case` scrutinee, so no call site may box that result on
# the way out. Invisible to an output diff -- boxing a scalar and
# immediately unboxing it changes nothing a program can print.

# `return idris2rc2_mk*(worker(...))` is the dual-ABI *wrapper* itself
# -- presenting a Boxed ABI is its entire job (doc/dual-abi.md's Stage
# 3a), so it is excluded. What must not appear is a *call site* boxing
# the result.
boxed="$(grep -E 'idris2rc2_mk[A-Za-z0-9]+\(idris2rc2_worker_Main_(scaledAbs|isBig)_' \
           "$TMP/${name}_rc2.c" | grep -cvE '^[[:space:]]*return ' || true)"
# And the branching-value promotion: `describeBoth`'s whole body is
# `&&` over two native predicate calls, so with the branch itself
# promoted it holds no boxing and no Boxed intermediate at all. Scans
# between the definition's own `{` and `}`; the forward declaration
# ends `);` instead and is skipped.
bodyboxed="$(awk '
    /^IDRIS2RC2_Value \*Main_describeBoth$/ { seen=1; next }
    seen && /^\{[[:space:]]*$/ { inbody=1; seen=0; next }
    seen && /^\)[[:space:]]*;/ { seen=0 }
    inbody && /^\}[[:space:]]*$/ { inbody=0 }
    inbody && /idris2rc2_mk/ { c++ }
    inbody && /IDRIS2RC2_Value \* var_[0-9]+ = NULL;/ { c++ }
    END { print c+0 }' "$TMP/${name}_rc2.c")"
if [ "$boxed" = "0" ] && [ "$bodyboxed" = "0" ]; then
    pass "DualABI native promotion -- case-scrutinee and branching-value worker results stay native"
elif [ "$boxed" != "0" ]; then
    fail "DualABI boxed $boxed case-scrutinee worker result(s) in $TMP/${name}_rc2.c"
else
    fail "DualABI left $bodyboxed boxing site(s) inside Main_describeBoth in $TMP/${name}_rc2.c"
fi

# A `Boxed` local bound directly to a comparison op (`<`, `<=`, `==`,
# `>=`, `>`) holds an `Int8` immediate, so `Compiler.RC2.RC` gives it no
# `dup`/`drop` at all (doc/native-type-inference.md, "Bool-producing
# comparison results"). Invisible to an output diff -- a refcount
# operation on an immediate is a runtime no-op. Scans the whole IR dump
# per definition: every `let vN : Boxed` whose value is such an op must
# never appear in a `dup vN` or a `drop [..]` list. The `boolcmp*`
# definitions in the test's own source supply the cases (some get
# inlined into `boolcmps`, hence the whole-dump scan); `cmps` guards
# against the scan matching nothing.
read -r cmps leftover < <(awk '
    /^def / { delete cmpvar; cur="" }
    /^ *let v[0-9]+ : Boxed =$/ { cur=$2; next }
    /^ *dup v[0-9]+$/ { if (substr($2,1) in cmpvar) bad++; next }
    /^ *op (<|>|==)/ { if (cur != "") { cmpvar[cur]=1; n++ }; cur=""; next }
    /^ *drop \[/ {
        line=$0; gsub(/[^v0-9,]/, "", line); m=split(line, ids, ",")
        for (i=1; i<=m; i++) if (ids[i] in cmpvar) bad++
        next }
    { cur="" }
    END { print n+0, bad+0 }' "$TMP/${name}_rc2.rcexpr")
# Since `Integer`/`String` comparisons fuse into a `cmp` over Boxed
# operands (doc/native-type-inference.md, "Comparisons over Boxed
# operands"), every `case` on one of these is a `cmp` node and no Bool
# local is bound at all; the guard is then the `cmp` nodes themselves.
fused="$(grep -cE '^ *cmp (<|>|==|<=|>=)(Integer|String) ' "$TMP/${name}_rc2.rcexpr" || true)"
if [ "$leftover" = "0" ] && { [ "$cmps" -gt 0 ] || [ "$fused" -ge 6 ]; }; then
    pass "Bool comparison results -- $cmps comparison-bound local(s) (none dup'd or dropped), $fused fused Integer/String cmp node(s)"
else
    fail "Bool comparison results: $cmps comparison-bound local(s), $leftover dup/drop of them, $fused fused cmp node(s) in $TMP/${name}_rc2.rcexpr"
fi

# Bool return (doc/dual-abi.md, "Bool return"): every `br*`/`eqBTree`
# function of the test is Bool-valued with Bool-or-call tails, so each
# must have a worker returning a native `Bits8` -- including
# `brDelegA`, whose only tail is a call. Invisible to an output diff.
rcexpr="$TMP/${name}_rc2.rcexpr"
nbits8() { grep -cE "^def \{idris2rc2_worker_Main_$1:[0-9]+\} .*ret= Native Bits8" "$2"; }
missing=""
for fn in eqBTree brCountLt brDelegA brSel2 brMixed brChain brDeepNot; do
    [ "$(nbits8 "$fn" "$rcexpr")" = "1" ] || missing="$missing $fn"
done
# The delegation tail and the self-recursive `&&` condition are direct
# calls to the callee's worker, not deferred calls.
deleg="$(awk '/^def \{idris2rc2_worker_Main_brDelegA:/ { on=1; next } /^def / { on=0 } on && /callRep \{idris2rc2_worker_Main_brCountLt:.*-> Native Bits8/ { c++ } END { print c+0 }' "$rcexpr")"
rec="$(awk '/^def \{idris2rc2_worker_Main_eqBTree:/ { on=1; next } /^def / { on=0 } on && /callRep \{idris2rc2_worker_Main_eqBTree:.*-> Native Bits8/ { c++ } END { print c+0 }' "$rcexpr")"
unreach="$(grep -c 'unreachable native' "$TMP/${name}_rc2.c" || true)"
if [ -z "$missing" ] && [ "$deleg" -ge 1 ] && [ "$rec" -ge 1 ] && [ "$unreach" = "0" ]; then
    pass "Bool return -- workers return native Bits8; delegation and recursion call them directly"
else
    fail "Bool return: no native Bits8 worker for:$missing; brDelegA tail callRep=$deleg, eqBTree callRep=$rec, unreachable=$unreach in $rcexpr"
fi

# Negative: with `--directive noboolret` the functions whose tails are
# calls (the rest already had literal tails, so were native before this
# rule) keep a Boxed return (the switch is the same-compiler
# before/after comparison).
rc2dir="$(cd "$(dirname "$0")/../.." && pwd)"
(cd "$rc2dir/tests" && "$rc2dir/build/exec/idris2-rc2" --cg rc2 --directive dumprcexpr --directive noboolret \
    "$name/$name.idr" -o "$TMP/${name}_noboolret" > "$TMP/${name}_noboolret.log" 2>&1)
still=""
for fn in brDelegA brSel2; do
    [ "$(nbits8 "$fn" "$TMP/${name}_noboolret.rcexpr")" = "0" ] || still="$still $fn"
done
if [ -f "$TMP/${name}_noboolret.rcexpr" ] && [ -z "$still" ]; then
    pass "Bool return -- --directive noboolret leaves no Bits8 worker for them"
else
    fail "Bool return: --directive noboolret still has a native Bits8 worker for:$still (see $TMP/${name}_noboolret.rcexpr)"
fi
