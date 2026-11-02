#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
# Constant aliases (Compiler.RC2.DeadVars, rc2/doc/dead-vars.md, "Constant
# aliases"): `let x = <constant>` and the `dup`/`drop` of x are gone, and
# with `--directive noconstalias` they are back. The output is the same.
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

here="$(cd "$(dirname "$0")" && pwd)"
rc2="$here/../../build/exec/idris2-rc2"
on="$TMP/${name}_rc2.rcexpr"
off="$TMP/${name}_noalias"

count() {  # dump -> number of `let` nodes that bind a bare constant
    awk '
        /^ *let v[0-9]+ : [A-Za-z0-9 ]+ =$/ { pending = 1; ind = match($0, /[^ ]/); next }
        pending {
            pending = 0
            i = match($0, /[^ ]/)
            t = $0; sub(/^ */, "", t)
            if (i > ind && (t ~ /^#/ || t ~ /^\[/ || t ~ /^-?[0-9]+$/)) n++
        }
        END { print n + 0 }' "$1"
}

if [ ! -f "$on" ]; then
    fail "no IR dump $on"
    exit 0
fi
if "$rc2" --cg rc2 --directive dumprcexpr --directive noconstalias "$here/$name.idr" -o "$off" \
        > "$off.log" 2>&1 && [ -f "$off.rcexpr" ]; then
    a="$(count "$on")"; b="$(count "$off.rcexpr")"
    if [ "$a" -lt "$b" ]; then
        pass "constant aliases -- $a lets bind a constant, against $b with --directive noconstalias"
    else
        fail "constant aliases -- $a lets bind a constant, not fewer than the $b with --directive noconstalias"
    fi
    if "$off" | cmp -s - "$here/$name.expected"; then
        pass "noconstalias -- same output"
    else
        fail "noconstalias -- the output differs from $name.expected"
    fi
else
    fail "noconstalias build failed, see $off.log"
fi
