#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

# Multi-apply closure specialisation (doc/speculative-closure-
# specialization.md, "Multiple apply chains"): callees applying the
# closure parameter 2-3 times get closure clones with no generic apply
# left (`twice`, `thrice`: 2-3 chains and `map f` forwarding;
# `fwd`: two chains and a self passthrough); `medium` and `big` (above
# SpecClosure.multiApplyMaxSize) get none, and neither does `twice` with
# a capturing closure (multi-apply is for constant closures only).
dump="$TMP/${name}_rc2.rcexpr"
for fn in twice thrice fwd; do
    clones="$(grep -cE "^def .*rc2_specClosure_Main_$fn" "$dump" || true)"
    generic="$(awk -v f="$fn" '/^def /{ins = ($0 ~ ("rc2_specClosure_Main_" f))} ins && /^ *apply|[^_]apply /' "$dump" | wc -l)"
    if [ "$clones" -ge 1 ] && [ "$generic" = "0" ]; then
        pass "$fn: $clones closure clone(s), no generic apply inside"
    else
        fail "$fn: expected >=1 closure clone ($clones) without apply ($generic) in $dump"
    fi
done
bigClones="$(grep -cE "^def .*rc2_specClosure_Main_(big|medium)" "$dump" || true)"
if [ "$bigClones" = "0" ]; then
    pass "big, medium: over the size threshold, no closure clone"
else
    fail "big, medium: $bigClones closure clone(s), expected 0 in $dump"
fi
