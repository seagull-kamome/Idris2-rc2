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
# must be gone from the C. `classify`'s two call sites pass two distinct
# constant dictionaries, so both clones have to land.
#
# Asserts that a stage *fired*, so `--directive nospecconstcon` makes
# it FAIL by design.
clones="$(grep -cE '^def \{rc2_specConst_' "$TMP/${name}_rc2.rcexpr" || true)"
dispatches="$(grep -c 'idris2rc2_applyClosure' "$TMP/${name}_rc2.c" || true)"
if [ "$clones" -ge 2 ] && [ "$dispatches" = "0" ]; then
    pass "SpecConstCon -- $clones clone(s) kept, no boxed closure dispatch left"
elif [ "$clones" -lt 2 ]; then
    fail "SpecConstCon kept $clones clone(s), expected at least 2, in $TMP/${name}_rc2.rcexpr"
else
    fail "SpecConstCon left $dispatches idris2rc2_applyClosure call(s) in $TMP/${name}_rc2.c"
fi
