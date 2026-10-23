#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

# A closure over constants only is a static, not a heap allocation
# (doc/static-closures.md). Invisible to an output diff. `tailer` tail-calls
# `g` with two integer literals: a saturated static, run by the trampoline each
# time (the case that frees, mutates or counts the closure if the static were
# not immortal).
n="$(grep -c '^  \.fn = (void \*)Main_g, \.args = { IDRIS2RC2_IMM_INT64' "$TMP/${name}_rc2.c" || true)"
if [ "$n" -ge 1 ]; then
    pass "static closures -- $n saturated static(s) of g in the generated C"
else
    fail "no static closure of Main_g over integer constants in $TMP/${name}_rc2.c"
fi
