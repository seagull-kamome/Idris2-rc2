#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
# Criterion A' (rc2/doc/inlining.md): a small body with calls is spliced into its callers;
# one over the bound is not.
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

here="$(cd "$(dirname "$0")" && pwd)"
rc2="$here/../../build/exec/idris2-rc2"
tests="$here/.."
on="$TMP/${name}_rc2.rcexpr"
off="$TMP/${name}_noinlinecalls"

if [ ! -f "$on" ]; then
    fail "no IR dump $on"
    exit 0
fi
if ! ( cd "$tests" && "$rc2" --cg rc2 --directive dumprcexpr --directive noinlinecalls "$name/$name.idr" -o "$off" ) \
        > "$off.log" 2>&1 || [ ! -f "$off.rcexpr" ]; then
    fail "noinlinecalls build failed, see $off.log"
    exit 0
fi
calls() { grep -cE "(call|callRep).*InlineWithCalls[._]$2[^A-Za-z0-9_]" "$1" || true; }
a="$(calls "$on" viaTwice)"
b="$(calls "$off.rcexpr" viaTwice)"
if [ "$a" = "0" ] && [ "$b" -ge 2 ]; then
    pass "viaTwice (5 nodes, calls shrink) -- $a calls, $b with --directive noinlinecalls"
else
    fail "calls of viaTwice: $a, $b with --directive noinlinecalls (want 0 and at least 2)"
fi
c="$(calls "$on" bigCalls)"
if [ "$c" -ge 2 ]; then
    pass "bigCalls, over the bound, stays a call ($c calls)"
else
    fail "calls of bigCalls: $c (want at least 2)"
fi
p="$(calls "$on" pick)"
q="$(calls "$off.rcexpr" pick)"
d="$(grep -c '^ *delay ' "$on" || true)"
e="$(grep -c '^ *delay ' "$off.rcexpr" || true)"
if [ "$p" = "0" ] && [ "$q" -ge 1 ] && [ "$d" -lt "$e" ]; then
    pass "pick (forces its Lazy default) -- $p calls, $q with noinlinecalls; delays $d against $e"
else
    fail "pick: calls $p (want 0), $q with noinlinecalls (want >= 1); delays $d against $e (want fewer)"
fi
if "$off" | cmp -s - "$here/$name.expected"; then
    pass "noinlinecalls -- same output"
else
    fail "noinlinecalls -- the output differs from $name.expected"
fi
