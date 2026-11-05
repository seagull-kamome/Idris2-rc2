#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

# A constructor that only a non-escaping callee reads is built in the frame
# (rc2/doc/stack-con.md): `once` and `twoLets` (whose fields are built in two
# `let`s inside the value) pass their `MkP` to `glue`, which only cases it. `twice`
# shares its `MkP` (a `dup`), `kept` stores one and `withDouble` holds a `Double`
# literal, boxed afresh when read, so those stay on the heap. `nested` builds its
# `MkW` in the frame and the `MkP` in its field too: `glueW` only passes that field to
# `glue`. `leaky` builds its `MkV` in the frame but not the `MkP` in it: `keepP` returns
# that field. `--directive nostackcon` has none.
here="$(cd "$(dirname "$0")" && pwd)"
rc2="$here/../../build/exec/idris2-rc2"
on="$TMP/${name}_rc2.rcexpr"
off="$TMP/${name}_nostackcon"

if [ ! -f "$on" ]; then
    fail "no IR dump $on"
    exit 0
fi
if ! "$rc2" --cg rc2 --directive dumprcexpr --directive nostackcon "$here/$name.idr" -o "$off" \
        > "$off.log" 2>&1 || [ ! -f "$off.rcexpr" ]; then
    fail "nostackcon build failed, see $off.log"
    exit 0
fi
a="$(grep -c '^ *stackcon ' "$on" || true)"
b="$(grep -c '^ *stackcon ' "$off.rcexpr" || true)"
if [ "$a" = "5" ] && [ "$b" = "0" ]; then
    pass "stack constructors -- $a with the pass, $b with --directive nostackcon"
else
    fail "stack constructors: $a with the pass (want 5), $b without (want 0)"
fi
if "$off" | cmp -s - "$here/$name.expected"; then
    pass "nostackcon -- same output"
else
    fail "nostackcon -- the output differs from $name.expected"
fi
