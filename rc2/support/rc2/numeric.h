#pragma once

#include "datatypes.h"
#include "memory.h"
#include <math.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Raw (unboxed) Euclidean division/modulo, used by the native-ABI codegen
// path (Compiler.RC2.Types/Emit) to compute on plain C locals without ever
// allocating a boxed value. Unsigned (Bits*) division is plain C '/'/'%'
// (already floored, since operands are non-negative) and needs no helper.
static inline int8_t idris2rc2_ediv_i8(int8_t n, int8_t d) {
  int8_t r = n % d;
  return n / d + ((r < 0) ? ((d < 0) ? 1 : -1) : 0);
}
static inline int8_t idris2rc2_emod_i8(int8_t n, int8_t d) {
  int8_t ad = (d < 0) ? -d : d;
  return n % ad + (n < 0 ? ad : 0);
}
static inline int16_t idris2rc2_ediv_i16(int16_t n, int16_t d) {
  int16_t r = n % d;
  return n / d + ((r < 0) ? ((d < 0) ? 1 : -1) : 0);
}
static inline int16_t idris2rc2_emod_i16(int16_t n, int16_t d) {
  int16_t ad = (d < 0) ? -d : d;
  return n % ad + (n < 0 ? ad : 0);
}
static inline int32_t idris2rc2_ediv_i32(int32_t n, int32_t d) {
  int32_t r = n % d;
  return n / d + ((r < 0) ? ((d < 0) ? 1 : -1) : 0);
}
static inline int32_t idris2rc2_emod_i32(int32_t n, int32_t d) {
  int32_t ad = (d < 0) ? -d : d;
  return n % ad + (n < 0 ? ad : 0);
}
static inline int64_t idris2rc2_ediv_i64(int64_t n, int64_t d) {
  int64_t r = n % d;
  return n / d + ((r < 0) ? ((d < 0) ? 1 : -1) : 0);
}
static inline int64_t idris2rc2_emod_i64(int64_t n, int64_t d) {
  int64_t ad = (d < 0) ? -d : d;
  return n % ad + (n < 0 ? ad : 0);
}

// X-macro table of the fixed-width integer PrimTypes: name token, C type,
// unboxing accessor, boxing constructor.
#define IDRIS2RC2_INTTYPES(F)                                                      \
  F(Int8, int8_t, idris2rc2_to_i8, idris2rc2_mkInt8)                                     \
  F(Int16, int16_t, idris2rc2_to_i16, idris2rc2_mkInt16)                                 \
  F(Int32, int32_t, idris2rc2_to_i32, idris2rc2_mkInt32)                                 \
  F(Int64, int64_t, idris2rc2_to_i64, idris2rc2_mkInt64)                                 \
  F(Bits8, uint8_t, idris2rc2_to_u8, idris2rc2_mkBits8)                                  \
  F(Bits16, uint16_t, idris2rc2_to_u16, idris2rc2_mkBits16)                              \
  F(Bits32, uint32_t, idris2rc2_to_u32, idris2rc2_mkBits32)                              \
  F(Bits64, uint64_t, idris2rc2_to_u64, idris2rc2_mkBits64)

// Most of the functions below are one-liners (a single boxed read, C
// operator, and boxed write) -- defined here as `static inline` rather than
// forward-declared and defined in numeric.c, so every translation unit that
// includes this header (in particular, every generated program .c file) can
// actually let the C compiler inline them at their call sites instead of
// always paying for a real function call for basic arithmetic/comparison/
// cast. Only the handful of genuinely multi-statement functions (real
// algorithms, or ones built on a shared non-trivial helper) stay defined in
// numeric.c, declared here as ordinary external functions same as before.

// ---- fixed-width integer arithmetic/bitwise ops (wrapping, matching C's
//      own overflow behaviour for the underlying width) ----

#define IDRIS2RC2_DEFOP(OPNAME, TY, CTY, GET, MK, OP)                              \
  static inline IDRIS2RC2_Value *idris2rc2_##OPNAME##_##TY(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) {  \
    return MK((CTY)(GET(a) OP GET(b)));                                     \
  }

#define IDRIS2RC2_ADD_DEF(TY, CTY, GET, MK) IDRIS2RC2_DEFOP(add, TY, CTY, GET, MK, +)
#define IDRIS2RC2_SUB_DEF(TY, CTY, GET, MK) IDRIS2RC2_DEFOP(sub, TY, CTY, GET, MK, -)
#define IDRIS2RC2_MUL_DEF(TY, CTY, GET, MK) IDRIS2RC2_DEFOP(mul, TY, CTY, GET, MK, *)
#define IDRIS2RC2_SHL_DEF(TY, CTY, GET, MK) IDRIS2RC2_DEFOP(shiftl, TY, CTY, GET, MK, <<)
#define IDRIS2RC2_SHR_DEF(TY, CTY, GET, MK) IDRIS2RC2_DEFOP(shiftr, TY, CTY, GET, MK, >>)
#define IDRIS2RC2_AND_DEF(TY, CTY, GET, MK) IDRIS2RC2_DEFOP(and, TY, CTY, GET, MK, &)
#define IDRIS2RC2_OR_DEF(TY, CTY, GET, MK) IDRIS2RC2_DEFOP(or, TY, CTY, GET, MK, |)
#define IDRIS2RC2_XOR_DEF(TY, CTY, GET, MK) IDRIS2RC2_DEFOP(xor, TY, CTY, GET, MK, ^)

IDRIS2RC2_INTTYPES(IDRIS2RC2_ADD_DEF)
IDRIS2RC2_INTTYPES(IDRIS2RC2_SUB_DEF)
IDRIS2RC2_INTTYPES(IDRIS2RC2_MUL_DEF)
IDRIS2RC2_INTTYPES(IDRIS2RC2_SHL_DEF)
IDRIS2RC2_INTTYPES(IDRIS2RC2_SHR_DEF)
IDRIS2RC2_INTTYPES(IDRIS2RC2_AND_DEF)
IDRIS2RC2_INTTYPES(IDRIS2RC2_OR_DEF)
IDRIS2RC2_INTTYPES(IDRIS2RC2_XOR_DEF)

#define IDRIS2RC2_CMPOP(OPNAME, TY, CTY, GET, MK, OP)                              \
  static inline IDRIS2RC2_Value *idris2rc2_##OPNAME##_##TY(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) {  \
    return idris2rc2_mkBool(GET(a) OP GET(b) ? 1 : 0);                             \
  }
#define IDRIS2RC2_LT_DEF(TY, CTY, GET, MK) IDRIS2RC2_CMPOP(lt, TY, CTY, GET, MK, <)
#define IDRIS2RC2_GT_DEF(TY, CTY, GET, MK) IDRIS2RC2_CMPOP(gt, TY, CTY, GET, MK, >)
#define IDRIS2RC2_EQ_DEF(TY, CTY, GET, MK) IDRIS2RC2_CMPOP(eq, TY, CTY, GET, MK, ==)
#define IDRIS2RC2_LTE_DEF(TY, CTY, GET, MK) IDRIS2RC2_CMPOP(lte, TY, CTY, GET, MK, <=)
#define IDRIS2RC2_GTE_DEF(TY, CTY, GET, MK) IDRIS2RC2_CMPOP(gte, TY, CTY, GET, MK, >=)

IDRIS2RC2_INTTYPES(IDRIS2RC2_LT_DEF)
IDRIS2RC2_INTTYPES(IDRIS2RC2_GT_DEF)
IDRIS2RC2_INTTYPES(IDRIS2RC2_EQ_DEF)
IDRIS2RC2_INTTYPES(IDRIS2RC2_LTE_DEF)
IDRIS2RC2_INTTYPES(IDRIS2RC2_GTE_DEF)

// Unsigned Bits* division/modulo is plain truncating (== floored, since
// operands are non-negative); signed Int* uses Euclidean division so that
// the remainder is always non-negative, matching Idris2's `div`/`mod`.
// Reference: Division and Modulus for Computer Scientists (Daan Leijen).
static inline IDRIS2RC2_Value *idris2rc2_div_Bits8(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBits8(idris2rc2_to_u8(a) / idris2rc2_to_u8(b)); }
static inline IDRIS2RC2_Value *idris2rc2_div_Bits16(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBits16(idris2rc2_to_u16(a) / idris2rc2_to_u16(b)); }
static inline IDRIS2RC2_Value *idris2rc2_div_Bits32(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBits32(idris2rc2_to_u32(a) / idris2rc2_to_u32(b)); }
static inline IDRIS2RC2_Value *idris2rc2_div_Bits64(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBits64(idris2rc2_to_u64(a) / idris2rc2_to_u64(b)); }
static inline IDRIS2RC2_Value *idris2rc2_mod_Bits8(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBits8(idris2rc2_to_u8(a) % idris2rc2_to_u8(b)); }
static inline IDRIS2RC2_Value *idris2rc2_mod_Bits16(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBits16(idris2rc2_to_u16(a) % idris2rc2_to_u16(b)); }
static inline IDRIS2RC2_Value *idris2rc2_mod_Bits32(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBits32(idris2rc2_to_u32(a) % idris2rc2_to_u32(b)); }
static inline IDRIS2RC2_Value *idris2rc2_mod_Bits64(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBits64(idris2rc2_to_u64(a) % idris2rc2_to_u64(b)); }

#define IDRIS2RC2_EUCLID_DIV(TY, CTY, GET, MK)                                     \
  static inline IDRIS2RC2_Value *idris2rc2_div_##TY(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) {         \
    CTY num = GET(a), denom = GET(b);                                       \
    CTY rem = num % denom;                                                   \
    return MK(num / denom + ((rem < 0) ? ((denom < 0) ? 1 : -1) : 0));       \
  }
#define IDRIS2RC2_EUCLID_MOD(TY, CTY, GET, MK)                                     \
  static inline IDRIS2RC2_Value *idris2rc2_mod_##TY(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) {         \
    CTY num = GET(a), denom = GET(b);                                       \
    denom = (denom < 0) ? -denom : denom;                                    \
    return MK(num % denom + (num < 0 ? denom : 0));                         \
  }
IDRIS2RC2_EUCLID_DIV(Int8, int8_t, idris2rc2_to_i8, idris2rc2_mkInt8)
IDRIS2RC2_EUCLID_DIV(Int16, int16_t, idris2rc2_to_i16, idris2rc2_mkInt16)
IDRIS2RC2_EUCLID_DIV(Int32, int32_t, idris2rc2_to_i32, idris2rc2_mkInt32)
IDRIS2RC2_EUCLID_DIV(Int64, int64_t, idris2rc2_to_i64, idris2rc2_mkInt64)
IDRIS2RC2_EUCLID_MOD(Int8, int8_t, idris2rc2_to_i8, idris2rc2_mkInt8)
IDRIS2RC2_EUCLID_MOD(Int16, int16_t, idris2rc2_to_i16, idris2rc2_mkInt16)
IDRIS2RC2_EUCLID_MOD(Int32, int32_t, idris2rc2_to_i32, idris2rc2_mkInt32)
IDRIS2RC2_EUCLID_MOD(Int64, int64_t, idris2rc2_to_i64, idris2rc2_mkInt64)

static inline IDRIS2RC2_Value *idris2rc2_negate_Int8(IDRIS2RC2_Value *x) { return idris2rc2_mkInt8(-idris2rc2_to_i8(x)); }
static inline IDRIS2RC2_Value *idris2rc2_negate_Int16(IDRIS2RC2_Value *x) { return idris2rc2_mkInt16(-idris2rc2_to_i16(x)); }
static inline IDRIS2RC2_Value *idris2rc2_negate_Int32(IDRIS2RC2_Value *x) { return idris2rc2_mkInt32(-idris2rc2_to_i32(x)); }
static inline IDRIS2RC2_Value *idris2rc2_negate_Int64(IDRIS2RC2_Value *x) { return idris2rc2_mkInt64(-idris2rc2_to_i64(x)); }
static inline IDRIS2RC2_Value *idris2rc2_negate_Double(IDRIS2RC2_Value *x) { return idris2rc2_mkDouble(-idris2rc2_to_double(x)); }

// ---- Double ----
static inline IDRIS2RC2_Value *idris2rc2_add_Double(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkDouble(idris2rc2_to_double(a) + idris2rc2_to_double(b)); }
static inline IDRIS2RC2_Value *idris2rc2_sub_Double(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkDouble(idris2rc2_to_double(a) - idris2rc2_to_double(b)); }
static inline IDRIS2RC2_Value *idris2rc2_mul_Double(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkDouble(idris2rc2_to_double(a) * idris2rc2_to_double(b)); }
static inline IDRIS2RC2_Value *idris2rc2_div_Double(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkDouble(idris2rc2_to_double(a) / idris2rc2_to_double(b)); }
static inline IDRIS2RC2_Value *idris2rc2_lt_Double(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBool(idris2rc2_to_double(a) < idris2rc2_to_double(b)); }
static inline IDRIS2RC2_Value *idris2rc2_gt_Double(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBool(idris2rc2_to_double(a) > idris2rc2_to_double(b)); }
static inline IDRIS2RC2_Value *idris2rc2_eq_Double(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBool(idris2rc2_to_double(a) == idris2rc2_to_double(b)); }
static inline IDRIS2RC2_Value *idris2rc2_lte_Double(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBool(idris2rc2_to_double(a) <= idris2rc2_to_double(b)); }
static inline IDRIS2RC2_Value *idris2rc2_gte_Double(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBool(idris2rc2_to_double(a) >= idris2rc2_to_double(b)); }

// ---- Char ----
static inline IDRIS2RC2_Value *idris2rc2_lt_Char(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBool(idris2rc2_to_char(a) < idris2rc2_to_char(b)); }
static inline IDRIS2RC2_Value *idris2rc2_gt_Char(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBool(idris2rc2_to_char(a) > idris2rc2_to_char(b)); }
static inline IDRIS2RC2_Value *idris2rc2_eq_Char(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBool(idris2rc2_to_char(a) == idris2rc2_to_char(b)); }
static inline IDRIS2RC2_Value *idris2rc2_lte_Char(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBool(idris2rc2_to_char(a) <= idris2rc2_to_char(b)); }
static inline IDRIS2RC2_Value *idris2rc2_gte_Char(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBool(idris2rc2_to_char(a) >= idris2rc2_to_char(b)); }

// ---- string (byte-wise; matches RefC's simplification of the spec) ----
// Conversions to/from string stay in numeric.c (multi-statement -- see the
// module note there); only these bare strcmp wrappers are one-liners.
static inline IDRIS2RC2_Value *idris2rc2_lt_string(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBool(strcmp(((IDRIS2RC2_String *)a)->str, ((IDRIS2RC2_String *)b)->str) < 0); }
static inline IDRIS2RC2_Value *idris2rc2_gt_string(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBool(strcmp(((IDRIS2RC2_String *)a)->str, ((IDRIS2RC2_String *)b)->str) > 0); }
static inline IDRIS2RC2_Value *idris2rc2_eq_string(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBool(strcmp(((IDRIS2RC2_String *)a)->str, ((IDRIS2RC2_String *)b)->str) == 0); }
static inline IDRIS2RC2_Value *idris2rc2_lte_string(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBool(strcmp(((IDRIS2RC2_String *)a)->str, ((IDRIS2RC2_String *)b)->str) <= 0); }
static inline IDRIS2RC2_Value *idris2rc2_gte_string(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBool(strcmp(((IDRIS2RC2_String *)a)->str, ((IDRIS2RC2_String *)b)->str) >= 0); }

// ---- Integer (arbitrary precision, via GMP) ----
// idris2rc2_div_Integer stays in numeric.c: a real multi-statement
// algorithm (Euclidean division built from mpz_mod/mpz_sub/mpz_divexact),
// not a one-liner.
static inline IDRIS2RC2_Value *idris2rc2_add_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) { IDRIS2RC2_Integer *r = idris2rc2_mkInteger(); mpz_add(r->v, ((IDRIS2RC2_Integer *)x)->v, ((IDRIS2RC2_Integer *)y)->v); return (IDRIS2RC2_Value *)r; }
static inline IDRIS2RC2_Value *idris2rc2_sub_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) { IDRIS2RC2_Integer *r = idris2rc2_mkInteger(); mpz_sub(r->v, ((IDRIS2RC2_Integer *)x)->v, ((IDRIS2RC2_Integer *)y)->v); return (IDRIS2RC2_Value *)r; }
static inline IDRIS2RC2_Value *idris2rc2_mul_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) { IDRIS2RC2_Integer *r = idris2rc2_mkInteger(); mpz_mul(r->v, ((IDRIS2RC2_Integer *)x)->v, ((IDRIS2RC2_Integer *)y)->v); return (IDRIS2RC2_Value *)r; }
static inline IDRIS2RC2_Value *idris2rc2_negate_Integer(IDRIS2RC2_Value *x) { IDRIS2RC2_Integer *r = idris2rc2_mkInteger(); mpz_neg(r->v, ((IDRIS2RC2_Integer *)x)->v); return (IDRIS2RC2_Value *)r; }
static inline IDRIS2RC2_Value *idris2rc2_mod_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) { IDRIS2RC2_Integer *r = idris2rc2_mkInteger(); mpz_mod(r->v, ((IDRIS2RC2_Integer *)x)->v, ((IDRIS2RC2_Integer *)y)->v); return (IDRIS2RC2_Value *)r; }
static inline IDRIS2RC2_Value *idris2rc2_shiftl_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) { IDRIS2RC2_Integer *r = idris2rc2_mkInteger(); mpz_mul_2exp(r->v, ((IDRIS2RC2_Integer *)x)->v, (mp_bitcnt_t)mpz_get_ui(((IDRIS2RC2_Integer *)y)->v)); return (IDRIS2RC2_Value *)r; }
static inline IDRIS2RC2_Value *idris2rc2_shiftr_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) { IDRIS2RC2_Integer *r = idris2rc2_mkInteger(); mpz_fdiv_q_2exp(r->v, ((IDRIS2RC2_Integer *)x)->v, (mp_bitcnt_t)mpz_get_ui(((IDRIS2RC2_Integer *)y)->v)); return (IDRIS2RC2_Value *)r; }
static inline IDRIS2RC2_Value *idris2rc2_and_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) { IDRIS2RC2_Integer *r = idris2rc2_mkInteger(); mpz_and(r->v, ((IDRIS2RC2_Integer *)x)->v, ((IDRIS2RC2_Integer *)y)->v); return (IDRIS2RC2_Value *)r; }
static inline IDRIS2RC2_Value *idris2rc2_or_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) { IDRIS2RC2_Integer *r = idris2rc2_mkInteger(); mpz_ior(r->v, ((IDRIS2RC2_Integer *)x)->v, ((IDRIS2RC2_Integer *)y)->v); return (IDRIS2RC2_Value *)r; }
static inline IDRIS2RC2_Value *idris2rc2_xor_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) { IDRIS2RC2_Integer *r = idris2rc2_mkInteger(); mpz_xor(r->v, ((IDRIS2RC2_Integer *)x)->v, ((IDRIS2RC2_Integer *)y)->v); return (IDRIS2RC2_Value *)r; }
static inline IDRIS2RC2_Value *idris2rc2_lt_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) { return idris2rc2_mkBool(mpz_cmp(((IDRIS2RC2_Integer *)x)->v, ((IDRIS2RC2_Integer *)y)->v) < 0); }
static inline IDRIS2RC2_Value *idris2rc2_gt_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) { return idris2rc2_mkBool(mpz_cmp(((IDRIS2RC2_Integer *)x)->v, ((IDRIS2RC2_Integer *)y)->v) > 0); }
static inline IDRIS2RC2_Value *idris2rc2_eq_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) { return idris2rc2_mkBool(mpz_cmp(((IDRIS2RC2_Integer *)x)->v, ((IDRIS2RC2_Integer *)y)->v) == 0); }
static inline IDRIS2RC2_Value *idris2rc2_lte_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) { return idris2rc2_mkBool(mpz_cmp(((IDRIS2RC2_Integer *)x)->v, ((IDRIS2RC2_Integer *)y)->v) <= 0); }
static inline IDRIS2RC2_Value *idris2rc2_gte_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) { return idris2rc2_mkBool(mpz_cmp(((IDRIS2RC2_Integer *)x)->v, ((IDRIS2RC2_Integer *)y)->v) >= 0); }

IDRIS2RC2_Value *idris2rc2_div_Integer(IDRIS2RC2_Value *, IDRIS2RC2_Value *);

// ---- casts ----
// Naming: idris2rc2_cast_<From>_to_<To>. Only the combinations actually
// referenced by a compiled program need to resolve at link time, so this
// covers the full numeric matrix plus Integer/Double/Char/string boundary
// conversions (matching what Idris2's Prelude actually exposes as `cast`).

// Numeric-to-numeric: unbox as the source C type, truncate/convert to the
// destination C type (matching C's own conversion rules), box the result.
#define IDRIS2RC2_CAST_NUM(FROM, FCTY, FGET, FMK, TO, TCTY, TMK)                   \
  static inline IDRIS2RC2_Value *idris2rc2_cast_##FROM##_to_##TO(IDRIS2RC2_Value *x) {         \
    return TMK((TCTY)(FGET(x)));                                             \
  }

#define IDRIS2RC2_CAST_TO_INT_MATRIX(FROM, FCTY, FGET, FMK)                        \
  IDRIS2RC2_CAST_NUM(FROM, FCTY, FGET, FMK, Int8, int8_t, idris2rc2_mkInt8)              \
  IDRIS2RC2_CAST_NUM(FROM, FCTY, FGET, FMK, Int16, int16_t, idris2rc2_mkInt16)           \
  IDRIS2RC2_CAST_NUM(FROM, FCTY, FGET, FMK, Int32, int32_t, idris2rc2_mkInt32)           \
  IDRIS2RC2_CAST_NUM(FROM, FCTY, FGET, FMK, Int64, int64_t, idris2rc2_mkInt64)           \
  IDRIS2RC2_CAST_NUM(FROM, FCTY, FGET, FMK, Bits8, uint8_t, idris2rc2_mkBits8)           \
  IDRIS2RC2_CAST_NUM(FROM, FCTY, FGET, FMK, Bits16, uint16_t, idris2rc2_mkBits16)        \
  IDRIS2RC2_CAST_NUM(FROM, FCTY, FGET, FMK, Bits32, uint32_t, idris2rc2_mkBits32)        \
  IDRIS2RC2_CAST_NUM(FROM, FCTY, FGET, FMK, Bits64, uint64_t, idris2rc2_mkBits64)        \
  IDRIS2RC2_CAST_NUM(FROM, FCTY, FGET, FMK, Double, double, idris2rc2_mkDouble)

IDRIS2RC2_INTTYPES(IDRIS2RC2_CAST_TO_INT_MATRIX)

// Split signed/unsigned (rather than one macro over all of
// IDRIS2RC2_INTTYPES): mpz_set_si takes a signed `long`, so routing an
// unsigned FCTY (e.g. Bits64's UINT64_MAX) through it reinterprets the
// value as negative before GMP ever sees it -- e.g. UINT64_MAX cast to
// Integer became -1 instead of 18446744073709551615. mpz_set_ui preserves
// the full unsigned magnitude.
#define IDRIS2RC2_CAST_SIGNED_TO_INTEGER(FROM, FCTY, FGET, FMK)                    \
  static inline IDRIS2RC2_Value *idris2rc2_cast_##FROM##_to_Integer(IDRIS2RC2_Value *x) { \
    IDRIS2RC2_Integer *r = idris2rc2_mkInteger();                                  \
    mpz_set_si(r->v, (long)FGET(x));                                               \
    return (IDRIS2RC2_Value *)r;                                                   \
  }
#define IDRIS2RC2_CAST_UNSIGNED_TO_INTEGER(FROM, FCTY, FGET, FMK)                  \
  static inline IDRIS2RC2_Value *idris2rc2_cast_##FROM##_to_Integer(IDRIS2RC2_Value *x) { \
    IDRIS2RC2_Integer *r = idris2rc2_mkInteger();                                  \
    mpz_set_ui(r->v, (unsigned long)FGET(x));                                      \
    return (IDRIS2RC2_Value *)r;                                                   \
  }
IDRIS2RC2_CAST_SIGNED_TO_INTEGER(Int8, int8_t, idris2rc2_to_i8, idris2rc2_mkInt8)
IDRIS2RC2_CAST_SIGNED_TO_INTEGER(Int16, int16_t, idris2rc2_to_i16, idris2rc2_mkInt16)
IDRIS2RC2_CAST_SIGNED_TO_INTEGER(Int32, int32_t, idris2rc2_to_i32, idris2rc2_mkInt32)
IDRIS2RC2_CAST_SIGNED_TO_INTEGER(Int64, int64_t, idris2rc2_to_i64, idris2rc2_mkInt64)
IDRIS2RC2_CAST_UNSIGNED_TO_INTEGER(Bits8, uint8_t, idris2rc2_to_u8, idris2rc2_mkBits8)
IDRIS2RC2_CAST_UNSIGNED_TO_INTEGER(Bits16, uint16_t, idris2rc2_to_u16, idris2rc2_mkBits16)
IDRIS2RC2_CAST_UNSIGNED_TO_INTEGER(Bits32, uint32_t, idris2rc2_to_u32, idris2rc2_mkBits32)
IDRIS2RC2_CAST_UNSIGNED_TO_INTEGER(Bits64, uint64_t, idris2rc2_to_u64, idris2rc2_mkBits64)

#define IDRIS2RC2_CAST_TO_CHAR(FROM, FCTY, FGET, FMK)                              \
  static inline IDRIS2RC2_Value *idris2rc2_cast_##FROM##_to_Char(IDRIS2RC2_Value *x) {         \
    return idris2rc2_mkChar((uint32_t)(uint8_t)FGET(x));                          \
  }
IDRIS2RC2_INTTYPES(IDRIS2RC2_CAST_TO_CHAR)

// idris2rc2_cast_<Int8/16/32/64/Bits8/16/32/64>_to_string stay in
// numeric.c: each is multi-statement (measure with snprintf, allocate,
// format), not a one-liner.
#define IDRIS2RC2_CAST_TO_STRING_DECL(FROM, FCTY, FGET, FMK) \
  IDRIS2RC2_Value *idris2rc2_cast_##FROM##_to_string(IDRIS2RC2_Value *);
IDRIS2RC2_INTTYPES(IDRIS2RC2_CAST_TO_STRING_DECL)

// ---- Double ----
static inline IDRIS2RC2_Value *idris2rc2_cast_Double_to_Int8(IDRIS2RC2_Value *x) { return idris2rc2_mkInt8((int8_t)idris2rc2_to_double(x)); }
static inline IDRIS2RC2_Value *idris2rc2_cast_Double_to_Int16(IDRIS2RC2_Value *x) { return idris2rc2_mkInt16((int16_t)idris2rc2_to_double(x)); }
static inline IDRIS2RC2_Value *idris2rc2_cast_Double_to_Int32(IDRIS2RC2_Value *x) { return idris2rc2_mkInt32((int32_t)idris2rc2_to_double(x)); }
static inline IDRIS2RC2_Value *idris2rc2_cast_Double_to_Int64(IDRIS2RC2_Value *x) { return idris2rc2_mkInt64((int64_t)idris2rc2_to_double(x)); }
static inline IDRIS2RC2_Value *idris2rc2_cast_Double_to_Bits8(IDRIS2RC2_Value *x) { return idris2rc2_mkBits8((uint8_t)idris2rc2_to_double(x)); }
static inline IDRIS2RC2_Value *idris2rc2_cast_Double_to_Bits16(IDRIS2RC2_Value *x) { return idris2rc2_mkBits16((uint16_t)idris2rc2_to_double(x)); }
static inline IDRIS2RC2_Value *idris2rc2_cast_Double_to_Bits32(IDRIS2RC2_Value *x) { return idris2rc2_mkBits32((uint32_t)idris2rc2_to_double(x)); }
static inline IDRIS2RC2_Value *idris2rc2_cast_Double_to_Bits64(IDRIS2RC2_Value *x) { return idris2rc2_mkBits64((uint64_t)idris2rc2_to_double(x)); }
static inline IDRIS2RC2_Value *idris2rc2_cast_Double_to_Integer(IDRIS2RC2_Value *x) { IDRIS2RC2_Integer *r = idris2rc2_mkInteger(); mpz_set_d(r->v, idris2rc2_to_double(x)); return (IDRIS2RC2_Value *)r; }
static inline IDRIS2RC2_Value *idris2rc2_cast_Double_to_Char(IDRIS2RC2_Value *x) { return idris2rc2_mkChar((uint32_t)(uint8_t)idris2rc2_to_double(x)); }
// idris2rc2_cast_Double_to_string stays in numeric.c (multi-statement).
IDRIS2RC2_Value *idris2rc2_cast_Double_to_string(IDRIS2RC2_Value *);

// ---- Char ----
static inline IDRIS2RC2_Value *idris2rc2_cast_Char_to_Int8(IDRIS2RC2_Value *x) { return idris2rc2_mkInt8((int8_t)idris2rc2_to_char(x)); }
static inline IDRIS2RC2_Value *idris2rc2_cast_Char_to_Int16(IDRIS2RC2_Value *x) { return idris2rc2_mkInt16((int16_t)idris2rc2_to_char(x)); }
static inline IDRIS2RC2_Value *idris2rc2_cast_Char_to_Int32(IDRIS2RC2_Value *x) { return idris2rc2_mkInt32((int32_t)idris2rc2_to_char(x)); }
static inline IDRIS2RC2_Value *idris2rc2_cast_Char_to_Int64(IDRIS2RC2_Value *x) { return idris2rc2_mkInt64((int64_t)idris2rc2_to_char(x)); }
static inline IDRIS2RC2_Value *idris2rc2_cast_Char_to_Bits8(IDRIS2RC2_Value *x) { return idris2rc2_mkBits8((uint8_t)idris2rc2_to_char(x)); }
static inline IDRIS2RC2_Value *idris2rc2_cast_Char_to_Bits16(IDRIS2RC2_Value *x) { return idris2rc2_mkBits16((uint16_t)idris2rc2_to_char(x)); }
static inline IDRIS2RC2_Value *idris2rc2_cast_Char_to_Bits32(IDRIS2RC2_Value *x) { return idris2rc2_mkBits32((uint32_t)idris2rc2_to_char(x)); }
static inline IDRIS2RC2_Value *idris2rc2_cast_Char_to_Bits64(IDRIS2RC2_Value *x) { return idris2rc2_mkBits64((uint64_t)idris2rc2_to_char(x)); }
static inline IDRIS2RC2_Value *idris2rc2_cast_Char_to_Integer(IDRIS2RC2_Value *x) { IDRIS2RC2_Integer *r = idris2rc2_mkInteger(); mpz_set_si(r->v, (long)idris2rc2_to_char(x)); return (IDRIS2RC2_Value *)r; }
// idris2rc2_cast_Char_to_string stays in numeric.c (multi-statement UTF-8
// encoding).
IDRIS2RC2_Value *idris2rc2_cast_Char_to_string(IDRIS2RC2_Value *);

// ---- Integer ----
// idris2rc2_cast_Integer_to_<Int8/16/32/64/Bits8/16/32/64/Char> and their
// shared idris2rc2_mpz_lsb helper, plus idris2rc2_cast_Integer_to_string,
// stay in numeric.c: mpz_lsb is itself multi-statement, and a `static`
// (file-local) helper can't be called from another translation unit's own
// inline copy of a caller, so anything built on it has to stay there too.
IDRIS2RC2_Value *idris2rc2_cast_Integer_to_Int8(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_Integer_to_Int16(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_Integer_to_Int32(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_Integer_to_Int64(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_Integer_to_Bits8(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_Integer_to_Bits16(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_Integer_to_Bits32(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_Integer_to_Bits64(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_Integer_to_Char(IDRIS2RC2_Value *);
static inline IDRIS2RC2_Value *idris2rc2_cast_Integer_to_Double(IDRIS2RC2_Value *x) { return idris2rc2_mkDouble(mpz_get_d(((IDRIS2RC2_Integer *)x)->v)); }
IDRIS2RC2_Value *idris2rc2_cast_Integer_to_string(IDRIS2RC2_Value *);

// ---- string ----
// idris2rc2_cast_string_to_<Char/Integer> stay in numeric.c (multi-
// statement UTF-8 decode / GMP parse); the rest are one-liners around
// atoi/atoll/atof.
static inline IDRIS2RC2_Value *idris2rc2_cast_string_to_Int8(IDRIS2RC2_Value *x) { return idris2rc2_mkInt8((int8_t)atoi(((IDRIS2RC2_String *)x)->str)); }
static inline IDRIS2RC2_Value *idris2rc2_cast_string_to_Int16(IDRIS2RC2_Value *x) { return idris2rc2_mkInt16((int16_t)atoi(((IDRIS2RC2_String *)x)->str)); }
static inline IDRIS2RC2_Value *idris2rc2_cast_string_to_Int32(IDRIS2RC2_Value *x) { return idris2rc2_mkInt32((int32_t)atoi(((IDRIS2RC2_String *)x)->str)); }
static inline IDRIS2RC2_Value *idris2rc2_cast_string_to_Int64(IDRIS2RC2_Value *x) { return idris2rc2_mkInt64((int64_t)atoll(((IDRIS2RC2_String *)x)->str)); }
static inline IDRIS2RC2_Value *idris2rc2_cast_string_to_Bits8(IDRIS2RC2_Value *x) { return idris2rc2_mkBits8((uint8_t)atoi(((IDRIS2RC2_String *)x)->str)); }
static inline IDRIS2RC2_Value *idris2rc2_cast_string_to_Bits16(IDRIS2RC2_Value *x) { return idris2rc2_mkBits16((uint16_t)atoi(((IDRIS2RC2_String *)x)->str)); }
static inline IDRIS2RC2_Value *idris2rc2_cast_string_to_Bits32(IDRIS2RC2_Value *x) { return idris2rc2_mkBits32((uint32_t)atoi(((IDRIS2RC2_String *)x)->str)); }
static inline IDRIS2RC2_Value *idris2rc2_cast_string_to_Bits64(IDRIS2RC2_Value *x) { return idris2rc2_mkBits64((uint64_t)atoll(((IDRIS2RC2_String *)x)->str)); }
static inline IDRIS2RC2_Value *idris2rc2_cast_string_to_Double(IDRIS2RC2_Value *x) { return idris2rc2_mkDouble(atof(((IDRIS2RC2_String *)x)->str)); }
IDRIS2RC2_Value *idris2rc2_cast_string_to_Integer(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_string_to_Char(IDRIS2RC2_Value *); // first UTF-8 codepoint, or NUL for ""
