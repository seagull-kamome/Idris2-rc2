#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
# Pushing an apply into the tails of `when`/`unless`/`if` over IO actions
# (rc2/doc/inlining.md, "Pushing an apply into the tails") leaves fewer
# partial applications than `--directive nopushapply`, and the same output.
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

here="$(cd "$(dirname "$0")" && pwd)"
rc2="$here/../../build/exec/idris2-rc2"
dump="$TMP/${name}_rc2.rcexpr"

"$rc2" --cg rc2 --directive dumprcexpr --directive nopushapply "$here/$name.idr" -o "$TMP/${name}_nopush" > "$TMP/${name}_nopush.log" 2>&1
off="$TMP/${name}_nopush.rcexpr"
if [ ! -f "$off" ]; then
    fail "--directive nopushapply build produced no IR dump (see $TMP/${name}_nopush.log)"
    exit 0
fi

if [ ! -f "$dump" ]; then
    fail "no IR dump $dump"
    exit 0
fi
on_n="$(grep -c 'partial ' "$dump" || true)"
off_n="$(grep -c 'partial ' "$off" || true)"
if [ "$on_n" -lt "$off_n" ]; then
    pass "partial applications: $on_n with the push, $off_n with --directive nopushapply"
else
    fail "expected fewer partial applications than nopushapply ($on_n against $off_n) in $dump"
fi

if [ "$("$TMP/${name}_nopush")" = "$(cat "$here/$name.expected")" ]; then
    pass "--directive nopushapply gives the same output"
else
    fail "--directive nopushapply output differs"
fi
