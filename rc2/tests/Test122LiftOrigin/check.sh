#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
set -u
TMP="$1"
name="$2"
lifts="$TMP/${name}_rc2.lifts"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

if [ ! -f "$lifts" ]; then
    fail "no $lifts: %cg rc2 dumplifts not honored"
    exit 0
fi

expect() {
    if grep -qxF "$2" "$lifts"; then pass "$1"; else fail "$1 -- no line '$2' in $lifts"; fi
}
expect "Lazy delay" "Main.{lazyValue:0}  from Main.lazyValue  delay Lazy  params 1"
expect "Inf delay" "Main.{countFrom:0}  from Main.countFrom  delay Inf  params 1"
expect "delay of a lambda, merged" "Main.{lazyAdder:0}  from Main.lazyAdder  delay Lazy  params 2"
expect "inner lambda, named first" "Main.{nested:0}  from Main.nested  lambda  params 1"
expect "outer lambda" "Main.{nested:1}  from Main.nested  lambda  params 1"
