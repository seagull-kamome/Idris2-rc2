#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
# A function that only calls another with its own parameters, in order, is an
# alias and is gone (rc2/doc/fwd-alias.md); `--directive nofwdalias` keeps it.
# Invisible to an output diff.
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

here="$(cd "$(dirname "$0")" && pwd)"
rc2="$here/../../build/exec/idris2-rc2"
on="$TMP/${name}_rc2.rcexpr"
off="$TMP/${name}_nofwdalias"

forwarders() {  # dump -> number of boxed functions that only forward their parameters
    awk '
        function flush(   i, n, ps, as, c) {
            if (def != "" && nbody == 1 && params != "") {
                if (match(body, /^ *(call|callRep) [^ ]+ /)) {
                    c = body
                    sub(/^ *callRep [^ ]+ \[[^]]*\] -> Boxed postDrop= \[\] /, "", c)
                    sub(/^ *call [^ ]+ /, "", c)
                    if (c == "[" params "]") count++
                }
            }
            def = ""; nbody = 0; body = ""
        }
        /^def / {
            flush()
            if ($0 ~ / ret= Boxed\)$/) {
                def = $2
                p = $0; sub(/^.*\(fun args= \[/, "", p); sub(/\] ret= Boxed\)$/, "", p)
                gsub(/"/, "", p); gsub(/:[A-Za-z]+( [A-Za-z0-9]+)?/, "", p)
                params = p
            }
            next
        }
        def != "" && NF { nbody++; body = $0 }
        END { flush(); print count + 0 }' "$1"
}

if [ ! -f "$on" ]; then
    fail "no IR dump $on"
    exit 0
fi
if ! "$rc2" --cg rc2 --directive dumprcexpr --directive nofwdalias "$here/$name.idr" -o "$off" \
        > "$off.log" 2>&1 || [ ! -f "$off.rcexpr" ]; then
    fail "nofwdalias build failed, see $off.log"
    exit 0
fi
a="$(forwarders "$on")"; b="$(forwarders "$off.rcexpr")"
if [ "$b" -ge 1 ] && [ "$a" -lt "$b" ]; then
    pass "forwarders -- $a left, against $b with --directive nofwdalias"
else
    fail "forwarders: $a left, $b with --directive nofwdalias (want fewer, and at least one to remove)"
fi
if "$off" | cmp -s - "$here/$name.expected"; then
    pass "nofwdalias -- same output"
else
    fail "nofwdalias -- the output differs from $name.expected"
fi
