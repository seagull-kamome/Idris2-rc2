#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
# An `apply` of the constant closure of a bare wrapper, given all the
# arguments of the function behind it at once, is a call
# (rc2/doc/const-closure-fold.md, "Over-application of a folded closure").
# Invisible to an output diff; `--directive noapplyfold` is the baseline.
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

here="$(cd "$(dirname "$0")" && pwd)"
rc2="$here/../../build/exec/idris2-rc2"
on="$TMP/${name}_rc2.rcexpr"
off="$TMP/${name}_noapplyfold"

if [ ! -f "$on" ]; then
    fail "no IR dump $on"
    exit 0
fi
if ! "$rc2" --cg rc2 -p contrib --directive dumprcexpr --directive noapplyfold "$here/$name.idr" -o "$off" \
        > "$off.log" 2>&1 || [ ! -f "$off.rcexpr" ]; then
    fail "noapplyfold build failed, see $off.log"
    exit 0
fi
count() { grep -cE '(^| )apply #[^ ]*~closure ' "$1" || true; }
a="$(count "$on")"; b="$(count "$off.rcexpr")"
if [ "$a" -lt "$b" ]; then
    pass "constant closures applied -- $a left, against $b with --directive noapplyfold"
else
    fail "constant closures applied: $a left, not fewer than the $b with --directive noapplyfold"
fi
if "$off" | cmp -s - "$here/$name.expected"; then
    pass "noapplyfold -- same output"
else
    fail "noapplyfold -- the output differs from $name.expected"
fi
