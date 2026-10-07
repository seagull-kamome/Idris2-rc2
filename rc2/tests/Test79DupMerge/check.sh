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

# Section 5: `dup v` ahead of a read-only node that releases `v` again
# through its own `postDrop` (op, extprim, comparison, call). The
# Integer/Int64/Double arithmetic ops are skipped on purpose: their
# runtime primitive consumes the operands itself (`Emit.idr` ignores
# their `postDrop`), so there the `dup` is a real reference.
pairs="$(awk '
    function indent_of(s) { match(s, /^ */); return RLENGTH }
    /^ *dup v[0-9]+( x[0-9]+)?$/ {
        i = indent_of($0)
        if (i != ind) { delete pend; ind = i }
        pend[$2] = 1
        next
    }
    {
        if (indent_of($0) == ind && match($0, /postDrop= \[[^]]*\]/) &&
            $0 !~ /^ *op ((\+|-|\*|%|&|\||\^|<<|>>|neg)[A-Za-z]|(shl|shr|and|or|xor) )/) {
            s = substr($0, RSTART + 11, RLENGTH - 12)
            k = split(s, vs, /, */)
            for (j = 1; j <= k; j++) if (vs[j] in pend) { bad++; break }
        }
        delete pend; ind = -1
    }
    END { print bad + 0 }
' "$TMP/${name}_rc2.rcexpr")"
if [ "$pairs" = "0" ]; then
    pass "DupMerge cancelRun -- no dup left paired with a postDrop of the same local"
else
    fail "DupMerge cancelRun left $pairs dup/postDrop pair(s) in $TMP/${name}_rc2.rcexpr"
fi

# The control for the check above: `integerLater`'s `dup` ahead of the
# consuming `*Integer` must survive, or the check could pass by
# cancelling too much (a use-after-free the valgrind run would catch
# only on this input).
if grep -B1 -E '^ *op \*Integer \[v[0-9]+, #3\]' "$TMP/${name}_rc2.rcexpr" | grep -qE '^ *dup v[0-9]+$'; then
    pass "DupMerge keeps the dup ahead of a reuse-consuming Integer op"
else
    fail "DupMerge dropped the dup ahead of the consuming *Integer in $TMP/${name}_rc2.rcexpr"
fi

# Alias lets: `let x = w` whose first mention is `drop [x]`
# (`readAll`'s inlined `readElems`) become `drop [w]`.
aliases="$(awk '
    function ind(s) { match(s, /^ */); return RLENGTH }
    /^ *let v[0-9]+ : Boxed =$/ { st = 1; li = ind($0); x = $2; next }
    st == 1 && /^ *v[0-9]+$/ { st = 2; next }
    st == 2 {
        if ($0 ~ /^ *dup v[0-9]+( x[0-9]+)?$/ && ind($0) == li) next
        if (ind($0) == li && $0 ~ /^ *drop \[/) {
            s = $0; sub(/^ *drop \[/, "", s); sub(/\]$/, "", s)
            k = split(s, vs, /, */)
            for (j = 1; j <= k; j++) if (vs[j] == x) { bad++; break }
        }
        st = 0
    }
    st == 1 { st = 0 }
    END { print bad + 0 }
' "$TMP/${name}_rc2.rcexpr")"
if [ "$aliases" = "0" ]; then
    pass "DupMerge alias let -- no \`let x = w\` left whose first mention is \`drop [x]\`"
else
    fail "DupMerge left $aliases alias let(s) dropped right away in $TMP/${name}_rc2.rcexpr"
fi
