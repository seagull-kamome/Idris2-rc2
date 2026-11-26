#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

# rc2/doc/join-points.md: in `walk` the copies end in `continue loop`, and
# the join point is inside the loop. `classify`, inlined into `main`, has
# no loop. Each join point takes at least two jumps.
dump="$TMP/${name}_rc2.rcexpr"
counts="$(awk '
    /^def / { name = $2; loop[name] = 0 }
    /^ *loop \[/ { loop[name] = 1 }
    /^ *join j[0-9]+ / { if (loop[name]) inLoop++; else outside++ }
    /^ *jump j[0-9]+ / { jumps++ }
    END { printf "%d %d %d", inLoop, outside, jumps }' "$dump")"
read -r inLoop outside jumps <<< "$counts"
if [ "$inLoop" -ge 1 ] && [ "$outside" -ge 1 ] && [ "$jumps" -ge $((2 * (inLoop + outside))) ]; then
    pass "$inLoop join point(s) in a loop, $outside outside one, $jumps jumps"
else
    fail "$inLoop join point(s) in a loop, $outside outside one, $jumps jumps (want >= 1 each, two jumps per join point) in $dump"
fi
# A native free local is passed as a native parameter.
if grep -qE '^ *join j[0-9]+ .*Native Int' "$dump"; then
    pass "a Native Int free local is a native parameter"
else
    fail "no join point takes a Native Int parameter in $dump"
fi
