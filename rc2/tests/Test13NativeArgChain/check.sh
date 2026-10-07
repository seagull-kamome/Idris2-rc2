#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

# `classify`/`describe` regression-check Compiler.RC2.DualABI's
# constant-`case` scrutinee promotion (`constCaseScrutineeNativeReads`,
# see the test's own comment): both workers return a native scalar read
# only as a `case` scrutinee, so no call site may box that result on
# the way out. Invisible to an output diff -- boxing a scalar and
# immediately unboxing it changes nothing a program can print.

# `return idris2rc2_mk*(worker(...))` is the dual-ABI *wrapper* itself
# -- presenting a Boxed ABI is its entire job (doc/dual-abi.md's Stage
# 3a), so it is excluded. What must not appear is a *call site* boxing
# the result.
boxed="$(grep -E 'idris2rc2_mk[A-Za-z0-9]+\(idris2rc2_worker_Main_(scaledAbs|isBig)_' \
           "$TMP/${name}_rc2.c" | grep -cvE '^[[:space:]]*return ' || true)"
# And the branching-value promotion: `describeBoth`'s whole body is
# `&&` over two native predicate calls, so with the branch itself
# promoted it holds no boxing and no Boxed intermediate at all. Scans
# between the definition's own `{` and `}`; the forward declaration
# ends `);` instead and is skipped.
bodyboxed="$(awk '
    /^IDRIS2RC2_Value \*Main_describeBoth$/ { seen=1; next }
    seen && /^\{[[:space:]]*$/ { inbody=1; seen=0; next }
    seen && /^\)[[:space:]]*;/ { seen=0 }
    inbody && /^\}[[:space:]]*$/ { inbody=0 }
    inbody && /idris2rc2_mk/ { c++ }
    inbody && /IDRIS2RC2_Value \* var_[0-9]+ = NULL;/ { c++ }
    END { print c+0 }' "$TMP/${name}_rc2.c")"
if [ "$boxed" = "0" ] && [ "$bodyboxed" = "0" ]; then
    pass "DualABI native promotion -- case-scrutinee and branching-value worker results stay native"
elif [ "$boxed" != "0" ]; then
    fail "DualABI boxed $boxed case-scrutinee worker result(s) in $TMP/${name}_rc2.c"
else
    fail "DualABI left $bodyboxed boxing site(s) inside Main_describeBoth in $TMP/${name}_rc2.c"
fi

# A `Boxed` local bound directly to a comparison op (`<`, `<=`, `==`,
# `>=`, `>`) holds an `Int8` immediate, so `Compiler.RC2.RC` gives it no
# `dup`/`drop` at all (doc/native-type-inference.md, "Bool-producing
# comparison results"). Invisible to an output diff -- a refcount
# operation on an immediate is a runtime no-op. Scans the whole IR dump
# per definition: every `let vN : Boxed` whose value is such an op must
# never appear in a `dup vN` or a `drop [..]` list. The `boolcmp*`
# definitions in the test's own source supply the cases (some get
# inlined into `boolcmps`, hence the whole-dump scan); `cmps` guards
# against the scan matching nothing.
read -r cmps leftover < <(awk '
    /^def / { delete cmpvar; cur="" }
    /^ *let v[0-9]+ : Boxed =$/ { cur=$2; next }
    /^ *dup v[0-9]+$/ { if (substr($2,1) in cmpvar) bad++; next }
    /^ *op (<|>|==)/ { if (cur != "") { cmpvar[cur]=1; n++ }; cur=""; next }
    /^ *drop \[/ {
        line=$0; gsub(/[^v0-9,]/, "", line); m=split(line, ids, ",")
        for (i=1; i<=m; i++) if (ids[i] in cmpvar) bad++
        next }
    { cur="" }
    END { print n+0, bad+0 }' "$TMP/${name}_rc2.rcexpr")
if [ "$cmps" -gt 0 ] && [ "$leftover" = "0" ]; then
    pass "Bool comparison results -- $cmps comparison-bound local(s), none dup'd or dropped"
else
    fail "Bool comparison results: $cmps comparison-bound local(s), $leftover dup/drop of them in $TMP/${name}_rc2.rcexpr"
fi
