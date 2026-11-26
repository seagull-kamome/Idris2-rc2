#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

# rc2/doc/const-caf-fold.md: no cast between Char and a constant integer,
# no Integer `x + 0`/`0 + x`/`x - 0` and no `"" ++ s`/`s ++ ""` is left.
dump="$TMP/${name}_rc2.rcexpr"
left="$(grep -cE '^ *op cast-[A-Za-z0-9]+-Char \[#|^ *op cast-Char-[A-Za-z0-9]+ \[#|^ *op [+-]Integer \[(v[0-9]+, #0|#0, v[0-9]+)\]|^ *op \+\+ \[(#"", |v[0-9]+, #""\])' "$dump" || true)"
if [ "$left" = 0 ]; then
    pass "every Char cast of a constant and every identity folded"
else
    fail "$left left in $dump"
fi
