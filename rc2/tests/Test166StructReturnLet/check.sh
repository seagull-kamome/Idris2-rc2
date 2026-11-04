#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

# `keep` switches on the result of `step` after a `let` that does not read it
# (doc/struct-return.md, "Calls whose case is not the next expression"): its
# worker receives the struct.
dump="$TMP/${name}_rc2.rcexpr"
got="$(awk '/^def \{idris2rc2_worker_Main_keep:/{p=1;next} /^def /{p=0} p' "$dump" | grep -c ': Ret1:1=Int =' || true)"
if [ "$got" = "1" ]; then
    pass "keep receives step's struct across a let"
else
    fail "keep has $got struct-typed lets, want 1, in $dump"
fi
