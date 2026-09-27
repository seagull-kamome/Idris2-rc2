#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

# `Int` literals and casts fold like `Int64`, and a large `Integer`
# literal lends its value to the cast reading it, so the literal-only
# half of each line builds no `Integer` at run time.
# `--directive noconstfold` fails this.
leftovers="$(grep -cE 'mkIntegerLiteral\("(18446744073709551621|9223372036854775807|4611686018427387904)"\)' "$TMP/${name}_rc2.c" || true)"
if [ "$leftovers" = "0" ]; then
    pass "Int constant folding -- no literal Integer left behind a folded cast"
else
    fail "$leftovers Integer literal(s) still built for a foldable Int cast in $TMP/${name}_rc2.c"
fi
