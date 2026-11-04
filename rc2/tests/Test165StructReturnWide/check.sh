#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

dump="$TMP/${name}_rc2.rcexpr"
five="$(grep -c "^def {idris2rc2_worker_Main_rot5:[0-9]*} .* ret= Ret5" "$dump" || true)"
eight="$(grep -c "^def {idris2rc2_worker_Main_rot8:[0-9]*} .* ret= Ret8" "$dump" || true)"
if [ "$five$eight" = "11" ]; then
    pass "struct return -- rot5 returns Ret5, rot8 returns Ret8"
else
    fail "struct workers five=$five eight=$eight in $dump"
fi
