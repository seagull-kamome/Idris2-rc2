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
# Integer/Int64/Double arithmetic ops and the string ops (`++` and the
# `op_str*` family) are skipped on purpose: their
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
            $0 !~ /^ *op ((\+|-|\*|%|&|\||\^|<<|>>|neg)[A-Za-z]|(shl|shr|and|or|xor) |\+\+ |op_str[a-z]+ )/) {
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

# Section 6 (Compiler.RC2.PushDown): a refcount-only run `dup v; ...;
# drop [parent]` right above `case v of` is moved into the arms, so no
# dup of the scrutinee is left in front of a case that has an arm opening
# with a drop of it (a dup no arm drops, e.g. a NIL arm that consumes it, is
# legitimate). `headHead`/`second` have that shape on every arm; compiled with
# `--directive nopushdown` the dump has it and this count is not zero.
hoisted="$(awk '
    function indent_of(s) { match(s, /^ */); return RLENGTH }
    function has_token(line, tok,    s, k, vs, j) {
        s = line; sub(/^ *drop \[/, "", s); sub(/\]$/, "", s)
        k = split(s, vs, /, */)
        for (j = 1; j <= k; j++) if (vs[j] == tok) return 1
        return 0
    }
    watch != "" && indent_of($0) <= cind { watch = ""; arm = 0 }
    watch != "" {
        i = indent_of($0)
        if (i == cind + 2 && $0 ~ /->$/) { arm = 1; next }
        if (arm && i == cind + 4 && $0 ~ /^ *drop \[/) { if (has_token($0, watch)) bad++; next }
        if (arm && i == cind + 4 && $0 ~ /^ *dup /) next
        arm = 0
    }
    /^ *dup v[0-9]+( x[0-9]+)?$/ {
        i = indent_of($0)
        if (i != ind) { delete pend; ind = i }
        pend[$2] = 1
        next
    }
    /^ *drop \[/ {
        if (indent_of($0) == ind) next
    }
    /^ *case v[0-9]+ of$/ {
        if (indent_of($0) == ind && ($2 in pend)) { watch = $2; cind = ind; arm = 0 }
    }
    { delete pend; ind = -1 }
    END { print bad + 0 }
' "$TMP/${name}_rc2.rcexpr")"

if [ "$hoisted" = "0" ]; then
    pass "PushDown -- no dup of a scrutinee left above the case whose arms drop it"
else
    fail "PushDown left $hoisted dup(s) of a scrutinee above its case in $TMP/${name}_rc2.rcexpr"
fi

# Section 7: Compiler.RC2.DeadVars blanks the binder of a constructor
# field nothing in the arm refers to (printed `_`). An output diff can't
# see it; with the pass off the same alts read `[vA, vB, vC]`.
first="$(grep -c 'Main.MkTriple .* args= \[v[0-9]*, _, _\] ->' "$TMP/${name}_rc2.rcexpr" || true)"
middle="$(grep -c 'Main.MkTriple .* args= \[_, v[0-9]*, _\] ->' "$TMP/${name}_rc2.rcexpr" || true)"
if [ "$first" -ge 1 ] && [ "$middle" -ge 1 ]; then
    pass "DeadVars -- unused MkTriple fields are blanked ([vN, _, _] x$first, [_, vN, _] x$middle)"
else
    fail "DeadVars did not blank the unused MkTriple fields in $TMP/${name}_rc2.rcexpr ([vN, _, _] x$first, [_, vN, _] x$middle)"
fi

# Section 8: in `leftLens` the last match is a `let`'s value. With the run
# pushed into its arms too, no local any `case` of the def matches is
# `dup`'d at all.
scrutDups="$(awk '
    /^def / { on = ($2 == "Main.leftLens") }
    on && /^ *case v[0-9]+ of$/ { scrut[$2] = 1 }
    on && /^ *dup v[0-9]+( x[0-9]+)?$/ { dups[$2] = 1 }
    END { for (v in dups) if (v in scrut) bad++; print bad + 0 }
' "$TMP/${name}_rc2.rcexpr")"
if [ "$scrutDups" = "0" ]; then
    pass "PushDown into a let's value -- leftLens dups no scrutinee"
else
    fail "PushDown left $scrutDups scrutinee dup(s) in leftLens in $TMP/${name}_rc2.rcexpr"
fi

# Every refcount-only run that Emit would write in fewer calls with all
# its dups first is in that order. A call is counted as Emit.Util's
# pendingLines makes them: consecutive plain dups or drops are batched,
# and a `dup v xN` is a call of its own.
late="$(awk '
    function indent_of(s) { match(s, /^ */); return RLENGTH }
    function batched(n) { if (n <= 2) return n; if (n <= 6 || n == 9) return 1; if (n <= 8) return 2; return 1 + batched(n - 6) }
    function calls(seq,    k, i, n, c, kind, t, m) {
        k = split(seq, t, " "); c = 0; kind = ""; n = 0
        for (i = 1; i <= k; i++) {
            m = substr(t[i], 2) + 0
            if (substr(t[i], 1, 1) == "X") { if (kind != "") c += batched(n); c++; kind = ""; n = 0; continue }
            if (substr(t[i], 1, 1) == kind) { n += m; continue }
            if (kind != "") c += batched(n)
            kind = substr(t[i], 1, 1); n = m
        }
        if (kind != "") c += batched(n)
        return c
    }
    function flush(    canon) {
        if (seq != "") {
            canon = (xs != "" ? xs " " : "") (ds > 0 ? "D" ds " " : "") (ps > 0 ? "P" ps : "")
            if (calls(canon) < calls(seq)) bad++
        }
        seq = ""; xs = ""; ds = 0; ps = 0; ind = -1
    }
    /^ *dup v[0-9]+( x[0-9]+)?$/ || /^ *drop \[/ {
        if (indent_of($0) != ind) { flush(); ind = indent_of($0) }
        if ($0 ~ /^ *dup .* x[0-9]+$/) { seq = seq " X1"; xs = xs " X1" }
        else if ($0 ~ /^ *dup /) { seq = seq " D1"; ds++ }
        else { s = $0; sub(/^ *drop \[/, "", s); sub(/\]$/, "", s); k = split(s, vs, /, */); seq = seq " P" k; ps += k }
        next
    }
    { flush() }
    END { flush(); print bad + 0 }
' "$TMP/${name}_rc2.rcexpr")"
if [ "$late" = "0" ]; then
    pass "Canonical runs -- no run Emit would write in fewer calls with its dups first"
else
    fail "$late run(s) Emit would write in fewer calls with their dups first in $TMP/${name}_rc2.rcexpr"
fi

# Section 9: no `case` whose every arm opens with a `dup` of the same
# local is left (a local bound inside one arm has an id of its own, so a
# local common to every arm is bound outside the `case`).
common="$(awk '
    function ind(s) { match(s, /^ */); return RLENGTH }
    { L[NR] = $0 }
    END {
        for (i = 1; i <= NR; i++) {
            if (L[i] !~ /^ *case v[0-9]+ of$/) continue
            ci = ind(L[i]); arms = 0; first = 1; delete common
            for (j = i + 1; j <= NR && ind(L[j]) > ci; j++) {
                if (ind(L[j]) != ci + 2 || L[j] !~ /->$/) continue
                arms++; delete here
                for (k = j + 1; k <= NR && ind(L[k]) == ci + 4; k++) {
                    s = L[k]; sub(/^ */, "", s)
                    if (s ~ /^dup v[0-9]+/) { split(s, q, " "); here[q[2]] = 1 }
                    else if (s !~ /^drop \[/) break
                }
                if (first) { for (v in here) common[v] = 1; first = 0 }
                else for (v in common) if (!(v in here)) delete common[v]
            }
            if (arms >= 2) for (v in common) { bad++; break }
        }
        print bad + 0
    }
' "$TMP/${name}_rc2.rcexpr")"
if [ "$common" = "0" ]; then
    pass "Common dups -- no case whose every arm opens with a dup of the same local"
else
    fail "$common case(s) whose every arm opens with a dup of the same local in $TMP/${name}_rc2.rcexpr"
fi

# Section 10: no local of `countLess` is `dup`'d in two places.
twice="$(awk '
    /^def / { on = ($2 == "Main.countLess") }
    on && /^ *dup v[0-9]+( x[0-9]+)?$/ { n[$2]++ }
    END { for (v in n) if (n[v] > 1) bad++; print bad + 0 }
' "$TMP/${name}_rc2.rcexpr")"
if [ "$twice" = "0" ]; then
    pass "DupMerge across a one-alt case -- countLess dups each local in one place"
else
    fail "DupMerge left $twice local(s) of countLess dup'd in two places in $TMP/${name}_rc2.rcexpr"
fi
