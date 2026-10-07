#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

# The suite's only exercise of Compiler.RC2.SpecClosure's constant-
# constructor specialization (doc/constant-constructor-specialization.md).
# Invisible to an output diff -- dispatching a method through
# idris2rc2_applyClosure and calling it directly print the same thing.
# Two checks, because either alone can be satisfied for the wrong
# reason: a clone must have been built AND kept (the profitability gate
# discards most attempts), and the boxed dispatch it exists to remove
# must be gone from the clones (read off the dump, not the whole C: the
# forwarding section below keeps run-time-dictionary calls, hence generic
# dispatch, elsewhere in the program). `classify`'s two call sites pass two distinct
# constant dictionaries, so both clones have to land.
#
# Asserts that a stage *fired*, so `--directive nospecconstcon` makes
# it FAIL by design.
clones="$(grep -cE '^def \{rc2_specConst_Main_' "$TMP/${name}_rc2.rcexpr" || true)"
dispatches="$(awk '/^def /{ins = ($0 ~ /rc2_specConst_Main_/)} ins && /apply /' "$TMP/${name}_rc2.rcexpr" | wc -l)"
if [ "$clones" -ge 2 ] && [ "$dispatches" = "0" ]; then
    pass "SpecConstCon -- $clones clone(s) kept, no boxed closure dispatch left"
elif [ "$clones" -lt 2 ]; then
    fail "SpecConstCon kept $clones clone(s), expected at least 2, in $TMP/${name}_rc2.rcexpr"
else
    fail "SpecConstCon left $dispatches apply line(s) inside a Main clone in $TMP/${name}_rc2.rcexpr"
fi

# Transitive constant-constructor specialization (ConstConForwarding,
# doc/constant-constructor-specialization.md, "Transitive
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
fwd="Test87SpecConstCon.ConstConForwarding"
fwdU="Test87SpecConstCon_ConstConForwarding"
chain2="$(grep -cE "^def .*rc2_specConst_${fwdU}_chain2" "$dump" || true)"
countAll="$(grep -cE "^def .*rc2_specConst_${fwdU}_countAll" "$dump" || true)"
# Every line inside a specConst clone of this module that still
# dispatches or calls the generic chain.
bad="$(awk -v u="rc2_specConst_${fwdU}_" -v m="${fwd}\\\\.(chain1|classify|countOne)" '/^def /{ins = index($0, u) > 0} ins && (/apply / || $0 ~ m)' "$dump" | wc -l)"
if [ "$chain2" -ge 2 ] && [ "$countAll" -ge 2 ] && [ "$bad" = "0" ]; then
    pass "SpecConstCon forwarding -- $chain2 chain2 and $countAll countAll clone(s) kept, no dispatch or generic chain call in a clone"
elif [ "$chain2" -lt 2 ] || [ "$countAll" -lt 2 ]; then
    fail "SpecConstCon forwarding kept $chain2 chain2 / $countAll countAll clone(s), expected at least 2 of each, in $dump"
else
    fail "SpecConstCon forwarding left $bad dispatch/generic-chain line(s) inside a clone in $dump"
fi
