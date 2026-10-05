#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

# Iteration of the specialization passes to a fixpoint
# (doc/speculative-closure-specialization.md, "Iteration"). The closure
# key `applyAll incr` only appears inside the clone the constant-
# constructor half builds for `run`, i.e. it needs a second round. Asserts
# the `run` clone calls a closure clone of `applyAll` and no longer the
# generic one, so a cap of one round, `--directive nospecclosure` and
# `--directive nospecconstcon` all make it FAIL by design.
dump="$TMP/${name}_rc2.rcexpr"
clones="$(grep -cE '^def .*rc2_specClosure_Main_applyAll' "$dump" || true)"
viaClone="$(awk '/^def /{ins = ($0 ~ /rc2_specConst_Main_run/)} ins && /call .*rc2_specClosure_Main_applyAll/' "$dump" | wc -l)"
generic="$(awk '/^def /{ins = ($0 ~ /rc2_specConst_Main_run/)} ins && /call Main\.applyAll/' "$dump" | wc -l)"
if [ "$clones" -ge 2 ] && [ "$viaClone" -ge 1 ] && [ "$generic" = "0" ]; then
    pass "second-round closure clone of applyAll: $clones clones kept, the run clone calls one ($viaClone site(s)), no generic call left"
else
    fail "expected >=2 applyAll closure clones ($clones), the run clone calling one ($viaClone) and not the generic one ($generic) in $dump"
fi
