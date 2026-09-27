#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

# `sumPos` returns a closure waiting for the world; raised
# (doc/world-arity-raising.md), its recursive call is a direct call, so
# its raised version gets a struct-returning worker with a native `Int`
# (`Ret1:1=Int`) and no `apply` of its own.
# `--directive noarityraise` fails this.
dump="$TMP/${name}_rc2.rcexpr"
raised="$(grep -c '^def {idris2rc2_worker_rc2_raised_Main_sumPos_[0-9]*:[0-9]*} .* ret= Ret1:1=Int ' "$dump" || true)"
applies="$(awk '/^def /{d=$2} /^ *apply /{if (d ~ /rc2_raised_Main_sumPos/) n++} END{print n+0}' "$dump")"
if [ "$raised" = "1" ] && [ "$applies" = "0" ]; then
    pass "arity raising -- sumPos's raised version returns Ret1:1=Int, no apply"
else
    fail "raised struct worker=$raised, applies in it=$applies in $dump"
fi
