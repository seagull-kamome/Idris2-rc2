#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

# LateInline splices the non-`%inline` `bind` into `run` after RC
# annotation, leaving closures built and applied at once; the post-RC
# fold (doc/world-arity-raising.md's "Post-RC fold") turns both into
# calls, so nothing in `run` applies a closure.
# `--directive noapplyfold` fails this.
applies="$(awk '/^def /{d=$2} /^ *apply /{if (d ~ /Main_run|Main\.run|Main\.\{run/) n++} END{print n+0}' "$TMP/${name}_rc2.rcexpr")"
if [ "$applies" = "0" ]; then
    pass "post-RC fold -- no apply left in run"
else
    fail "$applies apply(s) left in run in $TMP/${name}_rc2.rcexpr"
fi
