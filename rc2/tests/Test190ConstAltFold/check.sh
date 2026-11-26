#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

# rc2/doc/const-caf-fold.md, "Constant-case alts": the comparisons of
# `sign`, `dsign` and `isig` all fold but the Double `x == x`, which NaN
# makes false. (`main`'s own `traverse_` and `getArgs` compare Ints.)
dump="$TMP/${name}_rc2.rcexpr"
self="$(grep -cE '^ *cmp [^ ]+ \[(v[0-9]+), \1\]' "$dump" || true)"
selfD="$(grep -cE '^ *cmp ==Double \[(v[0-9]+), \1\]' "$dump" || true)"
left="$(grep -cE '^ *(cmp|op) (==|<|<=|>|>=)(Integer|Double) ' "$dump" || true)"
if [ "$self" = 1 ] && [ "$selfD" = 1 ] && [ "$left" = 1 ]; then
    pass "only the Double x == x is left of the Integer and Double comparisons"
else
    fail "$self self-comparison(s), $selfD of them Double ==, $left Integer/Double comparison(s) in $dump (want 1, 1, 1)"
fi
