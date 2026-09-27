#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

# Section 4 is the suite's ONLY exercise of Compiler.RC2.DupMerge's
# `cancelDupDrop` peephole -- no other test's dump has a cancellable
# pair. An output diff can't see the peephole at all, so without this
# it could stop firing and the suite would still pass. Re-derives the
# peephole's own rule over the dump: within a run of refcount-only
# nodes at one indent, no `dup v` may still be followed by a `drop`
# releasing that same `v`.
leftover="$(awk '
    function indent_of(s) { match(s, /^ */); return RLENGTH }
    /^ *dup v[0-9]+( x[0-9]+)?$/ {
        i = indent_of($0)
        if (i != ind) { delete pend; ind = i }
        pend[$2] += ($3 ~ /^x[0-9]+$/) ? substr($3, 2) + 0 : 1
        next
    }
    /^ *drop \[/ {
        i = indent_of($0)
        if (i != ind) { delete pend; ind = i; next }
        s = $0; sub(/^ *drop \[/, "", s); sub(/\]$/, "", s)
        k = split(s, vs, /, */)
        for (j = 1; j <= k; j++)
            if (pend[vs[j]] > 0) { pend[vs[j]]--; bad++ }
        next
    }
    { delete pend; ind = -1 }
    END { print bad + 0 }
' "$TMP/${name}_rc2.rcexpr")"
if [ "$leftover" = "0" ]; then
    pass "DupMerge cancelDupDrop -- no dup left paired with a later drop of the same local"
else
    fail "DupMerge cancelDupDrop left $leftover dup/drop pair(s) uncancelled in $TMP/${name}_rc2.rcexpr"
fi
