#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

# Compiler.RC2.Reuse's nested-let resolution (doc/reuse-analysis.md,
# "Nested let values"): the same-named constructor sits inside a `let`
# value, so the offered shell is claimed by `con ... reuse=` there. An
# output diff cannot see whether a claim happened at all (a missed one
# only costs a free + malloc), so count them per definition in the dump:
# `reuse=` claims and `releaseReuse` nodes of Main.bumpA..D, and of the
# inlined `revBump` loop (found inside Main.workload's worker).
counts() {  # dump -> "name reuse release" lines
    awk '
        /^def / { f = $2 }
        /reuse=/ { c[f]++ }
        /releaseReuse/ { r[f]++ }
        END { for (k in c) print k, c[k], r[k] + 0
              for (k in r) if (!(k in c)) print k, 0, r[k] }' "$1"
}
want() {  # dump def reuse-min release-min
    counts "$1" | awk -v d="$2" -v cm="$3" -v rm="$4" '
        index($1, d) { found = 1; if ($2 >= cm && $3 >= rm) ok = 1 }
        END { exit !(found && ok) }'
}

dump="$TMP/${name}_rc2.rcexpr"
bad=""
want "$dump" Main.bumpA 3 0 || bad="$bad bumpA(3 claims)"
want "$dump" Main.bumpB 1 1 || bad="$bad bumpB(1 claim + release)"
want "$dump" Main.bumpC 2 0 || bad="$bad bumpC(2 claims)"
want "$dump" Main.bumpD 2 0 || bad="$bad bumpD(2 claims)"
want "$dump" Main.bumpE 1 1 || bad="$bad bumpE(1 claim + release)"
want "$dump" Main_workload 2 0 || bad="$bad revBump-loop(2 claims)"
if [ -z "$bad" ]; then
    pass "nested-let reuse -- claims inside let-bound case/let values (case, partial-branch, nested let, call, loop)"
else
    fail "nested-let reuse missing:$bad in $dump"
fi

# Kill switch: with `--directive noreusenested` the same functions claim
# nothing (their offers are dead and release up front).
rc2="$(cd "$(dirname "$0")/../.." && pwd)/build/exec/idris2-rc2"
src="$(cd "$(dirname "$0")" && pwd)/$name.idr"
off="$TMP/${name}_nonested"
if "$rc2" --cg rc2 -p rc2base --directive dumprcexpr --directive noreusenested "$src" -o "$off" \
        > "$off.log" 2>&1 && [ -f "$off.rcexpr" ]; then
    claimed="$(counts "$off.rcexpr" | awk '/^Main\.bump/ && $2 > 0' | wc -l)"
    if [ "$claimed" = "0" ]; then
        pass "noreusenested -- no claim left in Main.bumpA..D"
    else
        fail "noreusenested still claims in $claimed of Main.bump*"
    fi
else
    fail "noreusenested compile failed, see $off.log"
fi

# Compiler.RC2.Reuse's re-check after DualABI (doc/reuse-analysis.md,
# "Re-checking dead offers after DualABI"): Main.chainE's offer on its
# parameter is claimed by the `Right` rebuilt after the inner struct-return
# call, as well as by the `Left` alt's own tail -- two claims. Without the
# pass (`--directive noreuserecheck`) only the `Left` claim is left.
if want "$dump" Main.chainE 2 1; then
    pass "reuse re-check -- Main.chainE claims its shell in both alts"
else
    fail "reuse re-check missing: Main.chainE has fewer than 2 claims in $dump"
fi
off2="$TMP/${name}_norecheck"
if "$rc2" --cg rc2 -p rc2base --directive dumprcexpr --directive noreuserecheck "$src" -o "$off2" \
        > "$off2.log" 2>&1 && [ -f "$off2.rcexpr" ]; then
    if counts "$off2.rcexpr" | awk '$1 == "Main.chainE" && $2 == 1 { ok = 1 } END { exit !ok }'; then
        pass "noreuserecheck -- Main.chainE keeps only the Left claim"
    else
        fail "noreuserecheck did not leave exactly one claim in Main.chainE"
    fi
else
    fail "noreuserecheck compile failed, see $off2.log"
fi
