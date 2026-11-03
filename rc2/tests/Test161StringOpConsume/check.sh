#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
# The string primitives that build a string drop their operands themselves
# (rc2/doc/rop-reuse.md, "String operations"), so the C has no drop right after
# a call of one of them, and the output (checked by verify.sh) is the same.
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

c="$TMP/${name}_rc2.c"
if [ ! -f "$c" ]; then
    fail "no C file $c"
    exit 0
fi
calls="$(grep -cE 'idris2rc2_(strAppend|strCons|strTail|strSubstr|strReverse|strIndex)\(' "$c" || true)"
dropped="$(awk '
    /idris2rc2_(strAppend|strCons|strTail|strSubstr|strReverse|strIndex)\(/ { on = 1; next }
    on && /^ *idris2rc2_drop\(/ { n++; next }
    { on = 0 }
    END { print n + 0 }' "$c")"
if [ "$calls" -ge 10 ] && [ "$dropped" = "0" ]; then
    pass "string primitives -- $calls calls, no drop after them"
else
    fail "string primitives: $calls calls, $dropped drop(s) right after them (want at least 10 and 0)"
fi
