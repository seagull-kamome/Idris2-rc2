#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
# A narrower integer cast to Integer and compared with a literal is compared
# in its own type, or decided at once (rc2/doc/widening-compare.md): the IR
# has far fewer Integer comparisons than with `--directive noconstfold`
# (which also gives the reference output; the output of the optimised build is
# compared with the same file by verify.sh).
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

here="$(cd "$(dirname "$0")" && pwd)"
rc2="$here/../../build/exec/idris2-rc2"
on="$TMP/${name}_rc2.rcexpr"
off="$TMP/${name}_noconstfold"

if [ ! -f "$on" ]; then
    fail "no IR dump $on"
    exit 0
fi
if ! "$rc2" --cg rc2 -p contrib --directive dumprcexpr --directive noconstfold "$here/$name.idr" -o "$off" \
        > "$off.log" 2>&1 || [ ! -f "$off.rcexpr" ]; then
    fail "noconstfold build failed, see $off.log"
    exit 0
fi
a="$(grep -c 'cmp [<>=]*Integer' "$on" || true)"
b="$(grep -c 'cmp [<>=]*Integer' "$off.rcexpr" || true)"
if [ "$((b - a))" -ge 30 ]; then
    pass "Integer comparisons -- $a left, against $b with --directive noconstfold (the dump holds the library too)"
else
    fail "Integer comparisons: $a left, $b with --directive noconstfold (want at least 30 fewer)"
fi
if "$off" | cmp -s - "$here/$name.expected"; then
    pass "noconstfold -- same output"
else
    fail "noconstfold -- the output differs from $name.expected"
fi
