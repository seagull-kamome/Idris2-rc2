#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

# ConstFold's known-constructor fold (doc/constructor-escape-analysis.md,
# "Rewrite A") is invisible to an output diff, so assert on the dump
# that `bump`'s non-escaping `Just` is gone. `--directive noconstfold`
# makes this FAIL by design.
justs="$(awk '/^def \{idris2rc2_worker_Main_bump:/{p=1; next} /^def /{p=0} p && /con _builtin.JUST/' "$TMP/${name}_rc2.rcexpr" | wc -l)"
if [ "$justs" = "0" ]; then
    pass "known-constructor fold -- bump's Just never built"
else
    fail "bump still builds $justs Just(s) in $TMP/${name}_rc2.rcexpr"
fi
# `score`'s chain result `Right (a + b)` is the only `Right` built in a
# matched cell (`reuse=`); PushCon's push (`--directive nopushcon`
# fails this) means it's never built.
rights="$(awk '/^def \{idris2rc2_worker_Main_score:/{p=1; next} /^def /{p=0} p && /con Prelude.Types.Right .* reuse=/' "$TMP/${name}_rc2.rcexpr" | wc -l)"
if [ "$rights" = "0" ]; then
    pass "case pushed into tails -- score's chain result never built"
else
    fail "score still builds its chain result Right in $TMP/${name}_rc2.rcexpr"
fi
