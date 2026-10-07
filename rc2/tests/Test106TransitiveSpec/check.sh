#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

dump="$TMP/${name}_rc2.rcexpr"

# SpecIterate: iteration of the specialization passes to a fixpoint
# (doc/speculative-closure-specialization.md, "Iteration"). The closure
# key `applyAll incr` only appears inside the clone the constant-
# constructor half builds for `run`, i.e. it needs a second round. Asserts
# the `run` clone calls a closure clone of `applyAll` and no longer the
# generic one, so a cap of one round, `--directive nospecclosure` and
# `--directive nospecconstcon` all make it FAIL by design.
it="Test106TransitiveSpec_SpecIterate"
clones="$(grep -cE "^def .*rc2_specClosure_${it}_applyAll" "$dump" || true)"
viaClone="$(awk -v r="rc2_specConst_${it}_run" '/^def /{ins = index($0, r) > 0} ins && /call .*rc2_specClosure_Test106TransitiveSpec_SpecIterate_applyAll/' "$dump" | wc -l)"
generic="$(awk -v r="rc2_specConst_${it}_run" '/^def /{ins = index($0, r) > 0} ins && /call Test106TransitiveSpec\.SpecIterate\.applyAll/' "$dump" | wc -l)"
if [ "$clones" -ge 2 ] && [ "$viaClone" -ge 1 ] && [ "$generic" = "0" ]; then
    pass "second-round closure clone of applyAll: $clones clones kept, the run clone calls one ($viaClone site(s)), no generic call left"
else
    fail "expected >=2 applyAll closure clones ($clones), the run clone calling one ($viaClone) and not the generic one ($generic) in $dump"
fi

# MultiApplySpec: closure specialisation of callees that apply the
# closure parameter more than once (doc/speculative-closure-
# specialization.md, "Multiple apply chains"): callees applying the
# closure parameter 2-3 times get closure clones with no generic apply
# left (`twice`, `thrice`: 2-3 chains and `map f` forwarding;
# `fwd`: two chains and a self passthrough); `medium` and `big` (above
# SpecClosure.multiApplyMaxSize) get none, and neither does `twice` with
# a capturing closure (multi-apply is for constant closures only).
ma="Test106TransitiveSpec_MultiApplySpec"
for fn in twice thrice fwd; do
    clones="$(grep -cE "^def .*rc2_specClosure_${ma}_$fn" "$dump" || true)"
    generic="$(awk -v f="rc2_specClosure_${ma}_$fn" '/^def /{ins = index($0, f) > 0} ins && (/^ *apply|[^_]apply /)' "$dump" | wc -l)"
    if [ "$clones" -ge 1 ] && [ "$generic" = "0" ]; then
        pass "$fn: $clones closure clone(s), no generic apply inside"
    else
        fail "$fn: expected >=1 closure clone ($clones) without apply ($generic) in $dump"
    fi
done
bigClones="$(grep -cE "^def .*rc2_specClosure_${ma}_(big|medium)" "$dump" || true)"
if [ "$bigClones" = "0" ]; then
    pass "big, medium: over the size threshold, no closure clone"
else
    fail "big, medium: $bigClones closure clone(s), expected 0 in $dump"
fi
