#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

bin="$TMP/${name}_rc2"

# A length the runtime cannot hold stops the program with a message on stderr
# and a failing status, before anything is written.
out="$("$bin" big 2>&1 >/dev/null)"
status=$?
if [ "$status" != "0" ] && printf '%s' "$out" | grep -q 'newArray: length'; then
    pass "a length past the runtime's limit stops the program: $(printf '%s' "$out" | head -1)"
else
    fail "expected a failing exit and a 'newArray: length' message, got status $status: $out"
fi
