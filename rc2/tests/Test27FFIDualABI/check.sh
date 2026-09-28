#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

# A constant passed to a Boxed %foreign argument position (the string
# literals given to prim__mixed/prim__mixed50, the constant closure
# given to prim__ignoreClosure) is a static value that is never freed,
# so the inlined call must not drop it. Invisible to an output diff:
# dropping an immortal value is a no-op at run time.
drops="$(grep -c 'idris2rc2_drop(((IDRIS2RC2_Value\*)&' "$TMP/${name}_rc2.c" || true)"
if [ "$drops" = "0" ]; then
    pass "FFI inline -- no drop of a constant argument"
else
    fail "FFI inline dropped $drops constant argument(s) in $TMP/${name}_rc2.c"
fi
