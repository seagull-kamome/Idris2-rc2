#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

# BoxedCompare: a `case` on an Integer/String comparison is one fused
# `cmp` node over the Boxed operands (doc/native-type-inference.md,
# "Comparisons over Boxed operands"), not `let v = op <Integer ..; case
# v of`. Invisible to an output diff. `cmps` guards against the scan
# matching nothing; the one `op ==Integer` + `case` pair that remains
# comes from Nat's `==` (the case scrutinises a variable there, not the
# comparison itself), so at most one pair is allowed.
dump="$TMP/${name}_rc2.rcexpr"
cmps="$(grep -cE '^ *cmp (<|>|==|<=|>=)(Integer|String) ' "$dump" || true)"
strs="$(grep -cE '^ *cmp (<|>|==|<=|>=)String ' "$dump" || true)"
pairs="$(awk '
    /^ *op (<|>|==|<=|>=)(Integer|String) / { ln=NR; next }
    ln && NR==ln+1 && /^ *case v[0-9]+ of/ { n++ }
    { ln=0 }
    END { print n+0 }' "$dump")"
if [ "$cmps" -ge 40 ] && [ "$strs" -ge 10 ] && [ "$pairs" -le 1 ]; then
    pass "Integer/String comparisons fused -- $cmps cmp node(s) ($strs on String), $pairs unfused op+case pair(s)"
else
    fail "Integer/String comparison fusion: $cmps cmp node(s) (want >=40), $strs on String (want >=10), $pairs unfused op+case pair(s) (want <=1) in $dump"
fi

# And at the C level: no Boxed Bool is built for them, the conditions are
# the `_raw` helpers (a plain C int).
raw="$(grep -cE 'int cmp_[0-9]+ = idris2rc2_(lt|gt|eq|lte|gte)_(Integer|string)_raw\(' "$TMP/${name}_rc2.c" || true)"
if [ "$raw" -ge "$cmps" ]; then
    pass "Integer/String comparisons -- $raw condition(s) are *_raw C int helpers"
else
    fail "only $raw *_raw conditions in $TMP/${name}_rc2.c for $cmps cmp node(s)"
fi

# CmpMerge: nested `<`/`==` (and `>`/`==`) comparisons of the same
# operands with equal branches become one `<=` (`>=`) node
# (doc/native-type-inference.md, "Merging nested comparisons"). Invisible
# to an output diff. Counted against the same compiler under
# `--directive nocmpmerge`: each type's shape functions in CmpMerge.idr
# (called once each, so one site each) give 3 `<=` and 3 `>=` nodes, plus
# one more `<=` on Int for the alpha-equivalent let branches; the shapes
# with differing branches or operands must add none, hence exact counts.
# The `compare`-based `<=`/`>=` are inlined or not by size, so they are
# not counted here (their output is diffed against RefC).
rc2dir="$(cd "$(dirname "$0")/../.." && pwd)"
(cd "$rc2dir/tests" && "$rc2dir/build/exec/idris2-rc2" --cg rc2 --directive dumprcexpr --directive nocmpmerge \
    "$name/$name.idr" -o "$TMP/${name}_nocmpmerge" > "$TMP/${name}_nocmpmerge.log" 2>&1)
off="$TMP/${name}_nocmpmerge.rcexpr"
if [ ! -f "$off" ]; then
    fail "CmpMerge: --directive nocmpmerge build produced no IR dump (see $TMP/${name}_nocmpmerge.log)"
else
    cnt() { grep -cE "^ *cmp $1$2 " "$3" || true; }
    bad=""
    for ty in Int Integer String Char Double; do
        wantLE=3; [ "$ty" = "Int" ] && wantLE=4
        dLE=$(( $(cnt '<=' "$ty" "$dump") - $(cnt '<=' "$ty" "$off") ))
        dGE=$(( $(cnt '>=' "$ty" "$dump") - $(cnt '>=' "$ty" "$off") ))
        dEQ=$(( $(cnt '==' "$ty" "$off") - $(cnt '==' "$ty" "$dump") ))
        { [ "$dLE" = "$wantLE" ] && [ "$dGE" = "3" ] && [ "$dEQ" -ge 6 ]; } || bad="$bad $ty(<=:+$dLE >=:+$dGE ==:-$dEQ)"
    done
    if [ -z "$bad" ]; then
        pass "nested comparison merge -- Int/Integer/String/Char/Double each gain the merged <=/>= nodes (--directive nocmpmerge is the comparison)"
    else
        fail "nested comparison merge, unexpected node-count change vs nocmpmerge:$bad (want <=:+3 (Int +4), >=:+3, ==:-6 or more)"
    fi
fi
