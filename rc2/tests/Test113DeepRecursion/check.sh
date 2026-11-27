#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

# TrmcHoles and TrmcMutual (rc2/doc/trmc.md, "Several hole indexes"):
# `alternate` fills field 1 of `A` and field 0 of `B`, so it fills
# `last . hk`, an index read at run time, not one constant index per
# branch of a `case` on `hk`. Inlining moves `alternate`'s loop into
# `main`, so this counts over the whole dump.
dump="$TMP/${name}_rc2.rcexpr"
varFills="$(grep -cE '^ *fill v[0-9]+ \. v[0-9]+ =' "$dump" || true)"
if [ "$varFills" -ge 1 ]; then
    pass "TrmcHoles: $varFills fill(s) at a run-time index"
else
    fail "TrmcHoles: no fill at a run-time index (want >= 1) in $dump"
fi

# A fill returns unit, C `NULL`, which annotate does not count
# (RC.alwaysUnboxedBoxedLocalsR): no `let` bound to a fill is dropped.
nullDrops="$(awk '
    /^ *let v[0-9]+ : Boxed =$/ { x = $2; st = 1; next }
    st == 1 { st = ($0 ~ /^ *fill /) ? 2 : 0; next }
    st == 2 { s = $0; sub(/^ */, "", s); if (s == "drop [" x "]") bad++; st = 0 }
    END { print bad + 0 }
' "$dump")"
if [ "$nullDrops" = "0" ]; then
    pass "TRMC: no fill result is dropped"
else
    fail "TRMC: $nullDrops fill result(s) dropped in $dump"
fi
