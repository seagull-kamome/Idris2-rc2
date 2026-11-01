#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RC2_DIR="$(dirname "$HERE")"
source "$(dirname "$RC2_DIR")/env.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL  $1"; exit 1; }

( cd "$RC2_DIR" && idris2 --build rc2.ipkg && idris2 --install rc2.ipkg && idris2 --build rc2-norepl.ipkg ) > "$TMP/build.log" 2>&1 || { cat "$TMP/build.log"; fail "idris2 --build rc2-norepl.ipkg"; }

NOREPL="$RC2_DIR/build/exec/idris2-rc2-norepl"
REF="$RC2_DIR/build/exec/idris2-rc2"

printf 'module Main\n\nmain : IO ()\nmain = putStrLn "hello from norepl"\n' > "$TMP/Hello.idr"
( cd "$TMP" && "$NOREPL" --cg rc2 Hello.idr -o hello_new && "$REF" --cg rc2 Hello.idr -o hello_ref ) > "$TMP/compile.log" 2>&1 || { cat "$TMP/compile.log"; fail "compile Hello"; }

[[ "$("$TMP/build/exec/hello_new")" == "hello from norepl" ]] || fail "the program built by idris2-rc2-norepl prints the wrong thing"
cmp -s "$TMP/build/exec/hello_new.c" "$TMP/build/exec/hello_ref.c" || fail "the C of idris2-rc2-norepl differs from the C of idris2-rc2"
echo "PASS  idris2-rc2-norepl compiles and gives the same C"

rc=0
"$NOREPL" < /dev/null > "$TMP/norepl.out" 2>&1 || rc=$?
[[ $rc -ne 0 ]] || fail "idris2-rc2-norepl with no arguments should not succeed"
grep -q "has no REPL" "$TMP/norepl.out" || fail "idris2-rc2-norepl with no arguments should say that it has no REPL"
for flag in --ide-mode --yaffle --repl --client; do
    rc=0
    "$NOREPL" "$flag" x > "$TMP/flag.out" 2>&1 < /dev/null || rc=$?
    [[ $rc -ne 0 ]] || fail "$flag should be refused"
done
echo "PASS  idris2-rc2-norepl refuses the REPL and its relatives"
