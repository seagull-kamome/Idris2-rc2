#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
# A closure that captured constants only is one immortal static
# (rc2/doc/const-closure-fold.md, "Closures over constants"): the generated C
# has `constpartial_N` statics, none with `--directive noconstfold` (which
# also gives the reference output).
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

here="$(cd "$(dirname "$0")" && pwd)"
rc2="$here/../../build/exec/idris2-rc2"
on="$TMP/${name}_rc2.c"
off="$TMP/${name}_noconstfold"

if [ ! -f "$on" ]; then
    fail "no C file $on"
    exit 0
fi
if ! "$rc2" --cg rc2 -p contrib --directive noconstfold "$here/$name.idr" -o "$off" \
        > "$off.log" 2>&1 || [ ! -x "$off" ]; then
    fail "noconstfold build failed, see $off.log"
    exit 0
fi
a="$(grep -c ' const constpartial_' "$on" || true)"
b="$(grep -c ' const constpartial_' "$off.c" || true)"
if [ "$a" -ge 3 ] && [ "$b" = "0" ]; then
    pass "constant closures -- $a statics, $b with --directive noconstfold"
else
    fail "constant closures: $a statics, $b with --directive noconstfold (want at least 3, and 0)"
fi
if "$off" | cmp -s - "$here/$name.expected"; then
    pass "noconstfold -- same output"
else
    fail "noconstfold -- the output differs from $name.expected"
fi
