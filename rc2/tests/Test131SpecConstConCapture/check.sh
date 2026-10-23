#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

# `twice` is called with the constant `Log IO` dictionary, which its
# continuation captures in a partial application. The clone must exist
# and hold no boxed closure dispatch, and the lifted continuation must
# be cloned with it (a call or a capture of the generic one would keep
# the dictionary alive). Invisible to an output diff.
#
# Asserts that a stage *fired*, so `--directive nospecconstcon` makes
# it FAIL by design.
dump="$TMP/${name}_rc2.rcexpr"
clones="$(grep -cE '^def \{rc2_specConst_Main_' "$dump" || true)"
dispatches="$(awk '/^def /{ins = ($0 ~ /rc2_specConst_Main_/)} ins && /apply /' "$dump" | wc -l)"
# The continuation's partial application inside a clone must point at a
# clone, not at the generic lifted lambda (which would keep the dictionary).
generic="$(awk '/^def /{ins = ($0 ~ /rc2_specConst_Main_/)} ins && /partial Main\.\{twice/' "$dump" | wc -l)"
if [ "$generic" != "0" ]; then
    fail "a clone still holds a partial application of the generic continuation in $dump"
elif [ "$clones" -ge 2 ] && [ "$dispatches" = "0" ]; then
    pass "SpecConstCon -- $clones clone(s) kept, no boxed closure dispatch left"
elif [ "$clones" -lt 2 ]; then
    fail "SpecConstCon kept $clones clone(s), expected at least 2, in $dump"
else
    fail "SpecConstCon left $dispatches apply line(s) inside a clone in $dump"
fi
