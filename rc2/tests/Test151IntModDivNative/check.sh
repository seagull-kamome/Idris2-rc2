#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
# mod/div by a constant: the op is bound by a native let, not a Boxed one
# (rc2/doc/native-type-inference.md, "Refreshing a rep after folding").
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

dump="$TMP/${name}_rc2.rcexpr"

total="$(grep -cE '^ *op (%|/)(Int|Int32|Bits8) \[' "$dump" || true)"
boxed="$(grep -B1 -E '^ *op (%|/)(Int|Int32|Bits8) \[[^]]*, #[0-9]+\]' "$dump" | grep -cE ': Boxed =$' || true)"
if [ "$total" -ge 4 ] && [ "$boxed" = "0" ]; then
    pass "mod/div by a constant: $total op(s), none bound by a Boxed let"
else
    fail "expected >=4 mod/div ops with none in a Boxed let, found $total op(s), $boxed Boxed in $dump"
fi
