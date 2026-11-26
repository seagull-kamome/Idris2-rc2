#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

# rc2/doc/const-caf-fold.md, "Constant-case alts": the alts no path can
# reach are gone -- in `again` those of 100, 200 and 300, in `digit` the
# two "bad" ones.
dump="$TMP/${name}_rc2.rcexpr"
dead="$(grep -cE '#(100|200|300)\b|#"bad"' "$dump" || true)"
if [ "$dead" = 0 ]; then
    pass "no unreachable alt left"
else
    fail "$dead unreachable alt(s) left in $dump"
fi
