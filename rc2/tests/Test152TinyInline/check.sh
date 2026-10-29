#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
# modifyIORef is spliced into its callers with the bind's closures gone
# (rc2/doc/inlining.md, "Criterion C: tiny callees"): no closure of the
# modifyIORef family is built any more (a direct call to its read wrapper is
# left, which is what Criterion C does not splice).
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

dump="$TMP/${name}_rc2.rcexpr"

left="$(grep -cE 'partial .*modifyIORef' "$dump" || true)"
if [ "$left" = "0" ]; then
    pass "no closure of the modifyIORef family is built"
else
    fail "$left partial application(s) of the modifyIORef family left in $dump"
fi
