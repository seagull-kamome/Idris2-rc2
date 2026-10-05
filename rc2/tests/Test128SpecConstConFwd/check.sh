#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

# Transitive constant-constructor specialization
# (doc/constant-constructor-specialization.md, "Transitive
# specialisation"). Invisible to an output diff. `chain2` and `countAll`
# are pure forwarders -- no `case` of their own -- so their clones exist
# only because the forwarded keys (`chain1`, `classify`, `countOne`)
# were built and accepted too, and a clone is only worth anything if no
# boxed dispatch and no call to the generic `chain1`/`classify` is left
# in it. `chain1`/`classify` are also called with a run-time dictionary,
# so the generic versions stay alive and any surviving reference to them
# from a clone would show up here.
#
# Asserts that a stage *fired*, so `--directive nospecconstcon` makes
# it FAIL by design.
dump="$TMP/${name}_rc2.rcexpr"
chain2="$(grep -cE '^def .*rc2_specConst_Main_chain2' "$dump" || true)"
countAll="$(grep -cE '^def .*rc2_specConst_Main_countAll' "$dump" || true)"
# Every line inside a specConst clone that still dispatches or calls
# the generic chain.
bad="$(awk '/^def /{ins = ($0 ~ /rc2_specConst_/)} ins && (/apply / || /Main\.(chain1|classify|countOne)/)' "$dump" | wc -l)"
if [ "$chain2" -ge 2 ] && [ "$countAll" -ge 2 ] && [ "$bad" = "0" ]; then
    pass "SpecConstCon forwarding -- $chain2 chain2 and $countAll countAll clone(s) kept, no dispatch or generic chain call in a clone"
elif [ "$chain2" -lt 2 ] || [ "$countAll" -lt 2 ]; then
    fail "SpecConstCon forwarding kept $chain2 chain2 / $countAll countAll clone(s), expected at least 2 of each, in $dump"
else
    fail "SpecConstCon forwarding left $bad dispatch/generic-chain line(s) inside a clone in $dump"
fi
