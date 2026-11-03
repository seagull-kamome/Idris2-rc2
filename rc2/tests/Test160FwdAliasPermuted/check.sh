#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
# A closure of a function that calls another with its captured parameters in
# another order is made of the other (rc2/doc/fwd-alias.md): the two closures
# `mkSwapped` makes become `partial Main.joined`; the one `mkRotated` makes
# (its missing parameter is not the last) stays.
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
a="$(grep -c 'partial Main.joined ' "$on" || true)"
b="$(grep -c 'partial Main.joined ' "$off.rcexpr" || true)"
if [ "$a" = "2" ] && [ "$b" = "0" ]; then
    pass "closures -- $a made of joined, $b with --directive nofwdalias"
else
    fail "closures: $a partial Main.joined, $b with --directive nofwdalias (want 2 and 0)"
fi
if "$off" | cmp -s - "$here/$name.expected"; then
    pass "nofwdalias -- same output"
else
    fail "nofwdalias -- the output differs from $name.expected"
fi
