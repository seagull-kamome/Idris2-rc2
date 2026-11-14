#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
# A local bound to strIndex/strHead or a cast to a small type is an immediate: no
# dup, drop or postDrop of it in the IR.
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }
dump="$TMP/${name}_rc2.rcexpr"
[ -f "$dump" ] || { fail "no IR dump $dump"; exit 0; }
# the locals bound to such an op, in the whole dump
vars="$(awk '/^ *let v[0-9]+ : Boxed =/ { v=$2; next } /^ *op (op_strindex|op_strhead|cast_[A-Za-z0-9]+_to_(Char|Bits8|Bits16|Bits32|Int8|Int16|Int32)) / && v != "" { print v } { if ($1 != "let") v="" }' "$dump" | sort -u)"
n="$(printf '%s\n' "$vars" | grep -c . || true)"
bad=0
for v in $vars; do
    if grep -qE "(dup $v( |$)|drop \[[^]]*\b$v\b|postDrop= \[[^]]*\b$v\b|dupOnShared= \[[^]]*\b$v\b)" "$dump"; then bad=$((bad + 1)); fi
done
if [ "$n" -ge 2 ] && [ "$bad" = "0" ]; then
    pass "$n Char/small-int op results, none with a dup, drop or postDrop"
else
    fail "$n such locals (want >= 2), $bad with a dup/drop/postDrop (want 0) in $dump"
fi
