#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
# --directive listfuse (rc2/doc/list-divert.md, "Fusion") makes one loop of a chain of
# map/filter/mapMaybe and of such a call followed by `++`: the named IR has fused loops
# of each shape, a foldl, foldr and length over a chain is one loop too, and the output is the same as the default build's.
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

here="$(cd "$(dirname "$0")" && pwd)"
rc2="$here/../../build/exec/idris2-rc2"
tests="$here/.."
on="$TMP/${name}_listfuse"

if ! ( cd "$tests" && "$rc2" --cg rc2 --directive dumpnamed --directive listfuse "$name/$name.idr" -o "$on" ) \
        > "$on.log" 2>&1 || [ ! -f "$on.named" ]; then
    fail "listfuse build failed, see $on.log"
    exit 0
fi
shapes="$(grep -o 'rc2_fuse_[a-z_]*' "$on.named" | sort -u | wc -l)"
if [ "$shapes" -ge 6 ]; then
    pass "listfuse: $shapes distinct fused loops in the named IR"
else
    fail "listfuse: $shapes distinct fused loops (want >= 6) in $on.named"
fi
if grep -q 'rc2_fuse_[a-z]*_t' "$on.named"; then
    pass "listfuse: a loop that ends in the second list of a ++"
else
    fail "listfuse: no fused loop with an end list in $on.named"
fi
consumers="$(grep -o 'rc2_\(foldl\|foldr\|length\)_[a-z]*' "$on.named" | sort -u | wc -l)"
if [ "$consumers" -ge 3 ]; then
    pass "listfuse: $consumers loops of a fold or length over a chain"
else
    fail "listfuse: $consumers fold/length loops (want >= 3) in $on.named"
fi
if "$on" | cmp -s - "$here/$name.expected"; then
    pass "listfuse -- same output"
else
    fail "listfuse -- the output differs from $name.expected"
fi
