#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
# A closure over a bare wrapper (`f params = partial g m params`) is a closure over
# what it wraps (rc2/doc/const-closure-fold.md, "Closures over a bare wrapper");
# `--directive noapplyfold` keeps them.
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

here="$(cd "$(dirname "$0")" && pwd)"
rc2="$here/../../build/exec/idris2-rc2"
on="$TMP/${name}_rc2.rcexpr"
off="$TMP/${name}_noapplyfold"

wrapperClosures() {  # dump -> number of closures (partial or constant) over a bare wrapper
    awk '
        function norm(s) { gsub(/[" ]/, "", s); return s }
        /^def / {
            def = $2
            p = $0; sub(/^.*\(fun args= \[/, "", p); sub(/\] ret=.*$/, "", p)
            gsub(/:[A-Za-z]+( [A-Za-z0-9]+)?/, "", p)
            params[def] = norm(p); nbody[def] = 0
            cur = def
            next
        }
        cur != "" && NF {
            nbody[cur]++
            if (nbody[cur] == 1) first[cur] = $0
        }
        { lines[NR] = $0 }
        END {
            for (d in nbody) if (nbody[d] == 1 && first[d] ~ /^ +partial /) {
                a = first[d]; sub(/^.*\[/, "", a); sub(/\]$/, "", a)
                if (norm(a) == params[d]) wrapper[d] = 1
            }
            for (i = 1; i <= NR; i++) {
                l = lines[i]
                if (l ~ /^ +partial /) { t = l; sub(/^ +partial /, "", t); sub(/ .*/, "", t); if (t in wrapper) n++ }
                while (match(l, /#[^ ,()]+\/[0-9]+~closure/)) {
                    t = substr(l, RSTART + 1, RLENGTH - 1); sub(/\/[0-9]+~closure$/, "", t)
                    if (t in wrapper) n++
                    l = substr(l, RSTART + RLENGTH)
                }
            }
            print n + 0
        }' "$1"
}

if [ ! -f "$on" ]; then
    fail "no IR dump $on"
    exit 0
fi
if ! "$rc2" --cg rc2 -p contrib --directive dumprcexpr --directive noapplyfold "$here/$name.idr" -o "$off" \
        > "$off.log" 2>&1 || [ ! -f "$off.rcexpr" ]; then
    fail "noapplyfold build failed, see $off.log"
    exit 0
fi
a="$(wrapperClosures "$on")"; b="$(wrapperClosures "$off.rcexpr")"
if [ "$b" -ge 1 ] && [ "$a" -lt "$b" ]; then
    pass "closures over a bare wrapper -- $a left, against $b with --directive noapplyfold"
else
    fail "closures over a bare wrapper: $a left, $b with --directive noapplyfold (want fewer, and at least one to remove)"
fi
if "$off" | cmp -s - "$here/$name.expected"; then
    pass "noapplyfold -- same output"
else
    fail "noapplyfold -- the output differs from $name.expected"
fi
