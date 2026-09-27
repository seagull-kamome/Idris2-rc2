#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

# DualABI's rewrites must reach inside a memoized CAF body
# (doc/caf-memoization.md, "Limitations"). Both `abs` calls in `table`
# spliced inline, none left as a call to the wrapper.
tableBody="$(awk '/^def Main.table /{p=1; next} /^def /{p=0} p' "$TMP/${name}_rc2.rcexpr")"
inlined="$(grep -c 'callFFIInline' <<< "$tableBody" || true)"
wrapped="$(grep -c 'call Main.prim__abs' <<< "$tableBody" || true)"
if [ "$inlined" = "2" ] && [ "$wrapped" = "0" ]; then
    pass "DualABI inside a memoized CAF -- both FFI calls inlined"
else
    fail "table has $inlined inlined and $wrapped wrapper FFI call(s) in $TMP/${name}_rc2.rcexpr"
fi
