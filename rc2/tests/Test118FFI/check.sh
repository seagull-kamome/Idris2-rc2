#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

here="$(cd "$(dirname "$0")" && pwd)"
c="$TMP/${name}_rc2.c"

# FFICExpr: what an output diff can't see about `CExpr:` declarations
# (rc2/doc/ffi-cexpr.md).

# Every FFICExpr declaration also carries a `C:` twin shim named
# idris2rc2_test128_*; `CExpr:` outranks it, so no shim is ever called or
# declared in the generated C, and (there being no symbol to name for a
# `CExpr:`) neither is a prototype of anything the expressions use.
shims="$(grep -c 'idris2rc2_test128_' "$c" || true)"
if [ "$shims" = "0" ]; then
    pass "CExpr outranks the C twin: no shim name in the generated C"
else
    fail "$shims reference(s) to an idris2rc2_test128_ shim in $c"
fi

# The header named by a `CExpr:` option is still #included.
missing=""
for h in fcntl.h errno.h limits.h stdlib.h string.h unistd.h Test128FFICExpr.h; do
    grep -qF "#include <$h>" "$c" || missing="$missing $h"
done
if [ -z "$missing" ]; then
    pass "CExpr header options are #included"
else
    fail "missing #include for:$missing"
fi

# Each marshalled argument sits inside its own parentheses, and the
# expression as a value inside one more pair: the inlined `abs` call of
# a constant, the generic wrapper's narrowing of a Bits8 argument, and
# a bare statement for an IO () declaration.
inl="$(grep -cE '\(abs\(\(INT32_C\(-5\)\)\)\)' "$c" || true)"
wrap="$(grep -cE 'retVal = \(\(\(\(idris2rc2_to_u8\(var_[0-9]+\)\)\)\) \+ 1\);' "$c" || true)"
stmt="$(grep -cE '^ *srand\(\(UINT32_C\(42\)\)\);' "$c" || true)"
if [ "$inl" -ge 1 ] && [ "$wrap" = "1" ] && [ "$stmt" -ge 1 ]; then
    pass "arguments and values parenthesised; IO () emitted as a statement"
else
    fail "parenthesised forms: inline abs $inl, Bits8 wrapper $wrap, srand statement $stmt in $c"
fi

# Integer results: `$r` expands to the allocated out-parameter inside the
# expression (`mpz_add(retVar->v, ...)`), emitted as a bare statement, and
# no implicit leading out-parameter is added on top (the `C:` convention).
# An Integer argument is marshalled as for `C:` (`idris2rc2_integerView`).
add="$(grep -cE '^ *mpz_add\(retVal->v, \(\(\(mpz_ptr\)idris2rc2_integerView\(var_1, [^;]*\(\(\(mpz_ptr\)idris2rc2_integerView\(var_2, [^;]*\);$' "$c" || true)"
inl="$(grep -cE '^ *mpz_pow_ui\(tmp_[0-9]+->v, \(\(\(mpz_ptr\)idris2rc2_integerView\(' "$c" || true)"
bad="$(grep -cE 'mpz_(add|mul|sub|pow_ui|set_si|set_ui)\(([a-zA-Z_0-9]+)->v, \2->v' "$c" || true)"
set1="$(grep -cE '^ *mpz_set_si\(retVal->v, \(long\)\(' "$c" || true)"
rep="$(grep -cE '^ *\(mpz_set_si\(retVal->v, 3\), mpz_mul\(retVal->v, .*, retVal->v\), mpz_add_ui\(retVal->v, retVal->v, 1\)\);$' "$c" || true)"
if [ "$add" -ge 1 ] && [ "$inl" -ge 1 ] && [ "$set1" -ge 1 ] && [ "$rep" -ge 1 ] && [ "$bad" = "0" ]; then
    pass "Integer result: \$r is the out-parameter, bare statement, no leading out-parameter"
else
    fail "Integer result forms: mpz_add $add, mpz_pow_ui inline $inl, mpz_set_si $set1, repeated \$r $rep, doubled out-parameter $bad in $c"
fi

# Compile-time errors: each program in CExprErrors/ must fail with the
# message in its .err file, produce no executable and not crash the
# compiler.
rc2c="$here/../../build/exec/idris2-rc2"
scratch="$TMP/${name}_cexprerrors"
for src in "$here"/CExprErrors/*.idr; do
    case="$(basename "$src" .idr)"
    rm -rf "$scratch/$case"
    actual="$(cd "$here/.." && "$rc2c" --cg rc2 --build-dir "$scratch/$case/b" \
                  --output-dir "$scratch/$case/o" "$src" -o cexpr_err_bin 2>&1)"
    bin="$(find "$scratch/$case" -name cexpr_err_bin -type f 2>/dev/null | head -1)"
    if [ -n "$bin" ]; then
        fail "CExprErrors/$case: compiled although it must be rejected"
    elif printf '%s\n' "$actual" | grep -q 'INTERNAL\|InternalError\|Uncaught'; then
        fail "CExprErrors/$case: internal compiler error: $actual"
    elif [ "$actual" = "$(cat "${src%.idr}.err")" ]; then
        pass "CExprErrors/$case: rejected with the expected message"
    else
        fail "CExprErrors/$case: message differs from ${case}.err: $actual"
    fi
done
