#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
# What the compiler does with `prim__os` under each `--directive target-os`
# value (rc2/doc/directives.md); the default (host) build is the one
# verify.sh itself compiled.
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

here="$(cd "$(dirname "$0")" && pwd)"
rc2="$here/../../build/exec/idris2-rc2"
src="$here/$name.idr"
dump="$TMP/${name}_rc2.rcexpr"

# The compiler exits 0 even when the C compiler fails, so the callers look
# for the executable.
compile() {
    local tag="$1"; shift
    "$rc2" --cg rc2 --directive dumprcexpr "$@" "$src" -o "$TMP/${name}_$tag" > "$TMP/${name}_$tag.log" 2>&1
}

if [ "$(grep -c prim__os "$dump" || true)" = "0" ]; then
    pass "default: prim__os folded to the host OS"
else
    fail "default: prim__os left in $dump"
fi

compile dynamic --directive target-os=dynamic
if [ "$(grep -c prim__os "$TMP/${name}_dynamic.rcexpr" || true)" != "0" ] \
   && [ "$("$TMP/${name}_dynamic")" = "$(cat "$here/$name.expected")" ]; then
    pass "target-os=dynamic: prim__os kept, same output"
else
    fail "target-os=dynamic: see $TMP/${name}_dynamic.log"
fi

# Linux is the only OS this suite runs on, so any other name is a cross build.
compile cross --directive target-os=windows
if [ ! -x "$TMP/${name}_cross" ] && grep -q 'but this C compiler targets another OS' "$TMP/${name}_cross.log"; then
    pass "target-os=windows on this host: the C compiler stops the build"
else
    fail "target-os=windows was accepted or failed another way: see $TMP/${name}_cross.log"
fi

compile bogus --directive target-os=bogus
if [ ! -x "$TMP/${name}_bogus" ] && grep -q "unknown target-os 'bogus'" "$TMP/${name}_bogus.log"; then
    pass "target-os=bogus: rejected"
else
    fail "target-os=bogus: see $TMP/${name}_bogus.log"
fi

compile conflict --directive target-os=Linux --directive target-os=dynamic
if [ ! -x "$TMP/${name}_conflict" ] && grep -q 'conflicting target-os' "$TMP/${name}_conflict.log"; then
    pass "conflicting target-os values: rejected"
else
    fail "conflicting target-os values: see $TMP/${name}_conflict.log"
fi
