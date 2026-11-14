#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
# The calls of a one-line wrapper that adds constants (the selector and the padding `MutualLoop`
# leaves) are calls of the merged function (rc2/doc/fwd-alias.md, "Constants added"), and the
# wrappers are gone.
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

here="$(cd "$(dirname "$0")" && pwd)"
rc2="$here/../../build/exec/idris2-rc2"
on="$TMP/${name}_rc2.rcexpr"
off="$TMP/${name}_nofwdalias"

if [ ! -f "$on" ]; then
    fail "no IR dump $on"
    exit 0
fi
if ! "$rc2" --cg rc2 --directive dumprcexpr --directive nofwdalias "$here/$name.idr" -o "$off" \
        > "$off.log" 2>&1 || [ ! -f "$off.rcexpr" ]; then
    fail "nofwdalias build failed, see $off.log"
    exit 0
fi
a="$(grep -cE 'call(Rep)? Main\.(ping|pong) ' "$on" || true)"
b="$(grep -cE 'call(Rep)? Main\.(ping|pong) ' "$off.rcexpr" || true)"
if [ "$a" = "0" ] && [ "$b" -gt 0 ]; then
    pass "calls of the wrappers -- $a, $b with --directive nofwdalias"
else
    fail "calls of Main.ping/Main.pong: $a, $b with --directive nofwdalias (want 0 and more than 0)"
fi
d="$(grep -cE '^def Main\.(ping|pong) ' "$on" || true)"
if [ "$d" = "0" ]; then
    pass "the wrappers are removed"
else
    fail "$d wrapper definition(s) left"
fi
if "$off" | cmp -s - "$here/$name.expected"; then
    pass "nofwdalias -- same output"
else
    fail "nofwdalias -- the output differs from $name.expected"
fi
