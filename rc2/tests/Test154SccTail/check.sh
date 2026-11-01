#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
# Direct tail calls out of a strongly connected component of the tail-call
# graph (Compiler.RC2.LeafTail, rc2/doc/leaf-tail-calls.md): `viaLoop`
# calls `loopy`, which is not a leaf (it ends in a loop), by a direct call.
# A cycle of tail calls that stays a cycle (`--directive nomutualloop
# --directive noloop`) keeps its closures, and a million bounces still run.
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

here="$(cd "$(dirname "$0")" && pwd)"
rc2="$here/../../build/exec/idris2-rc2"
inl="--directive noinline --directive noearlyinline --directive nolateinline --directive notinyinline"
for mode in on off; do
    extra=""
    [ "$mode" = off ] && extra="--directive noleaftail"
    "$rc2" --cg rc2 --directive dumprcexpr $inl $extra "$here/$name.idr" -o "$TMP/${name}_direct_$mode" \
        > "$TMP/${name}_direct_$mode.log" 2>&1
done
if [ -f "$TMP/${name}_direct_on.rcexpr" ] && [ -f "$TMP/${name}_direct_off.rcexpr" ] \
        && grep -Eq '^ *callRep Main\.loopy ' "$TMP/${name}_direct_on.rcexpr" \
        && ! grep -Eq '^ *callRep Main\.loopy ' "$TMP/${name}_direct_off.rcexpr"; then
    pass "viaLoop calls the non-leaf loopy directly, and only with the pass on"
else
    fail "no direct tail call of Main.loopy (or one with --directive noleaftail) in $TMP/${name}_direct_*.rcexpr, see $TMP/${name}_direct_*.log"
fi

off="$TMP/${name}_cycle"
if "$rc2" --cg rc2 --directive dumprcexpr --directive nomutualloop --directive noloop "$here/$name.idr" -o "$off" \
        > "$off.log" 2>&1 && [ -f "$off.rcexpr" ]; then
    if ! grep -Eq '^ *call Main\.(ping|pong) ' "$off.rcexpr"; then
        fail "no closure tail call of ping or pong in $off.rcexpr"
    elif grep -Eq '^ *callRep Main\.(ping|pong) ' "$off.rcexpr"; then
        fail "ping and pong call each other directly although they form a cycle in $off.rcexpr"
    else
        pass "ping and pong keep their tail calls as closures"
    fi
    if "$off" | cmp -s - "$here/$name.expected"; then
        pass "the cycle of a million bounces runs in constant stack"
    else
        fail "the cycle build prints something else than $name.expected"
    fi
else
    fail "cycle build failed, see $off.log"
fi
