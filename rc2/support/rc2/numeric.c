#include "numeric.h"

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ---- fixed-width integer arithmetic/bitwise ops (wrapping, matching C's
//      own overflow behaviour for the underlying width) ----

#define IDRIS2RC2_DEFOP(OPNAME, TY, CTY, GET, MK, OP)                              \
  IDRIS2RC2_Value *idris2rc2_##OPNAME##_##TY(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) {               \
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
  IDRIS2RC2_Value *idris2rc2_##OPNAME##_##TY(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) {               \
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
IDRIS2RC2_Value *idris2rc2_div_Bits8(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBits8(idris2rc2_to_u8(a) / idris2rc2_to_u8(b)); }
IDRIS2RC2_Value *idris2rc2_div_Bits16(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBits16(idris2rc2_to_u16(a) / idris2rc2_to_u16(b)); }
IDRIS2RC2_Value *idris2rc2_div_Bits32(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBits32(idris2rc2_to_u32(a) / idris2rc2_to_u32(b)); }
IDRIS2RC2_Value *idris2rc2_div_Bits64(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBits64(idris2rc2_to_u64(a) / idris2rc2_to_u64(b)); }
IDRIS2RC2_Value *idris2rc2_mod_Bits8(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBits8(idris2rc2_to_u8(a) % idris2rc2_to_u8(b)); }
IDRIS2RC2_Value *idris2rc2_mod_Bits16(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBits16(idris2rc2_to_u16(a) % idris2rc2_to_u16(b)); }
IDRIS2RC2_Value *idris2rc2_mod_Bits32(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBits32(idris2rc2_to_u32(a) % idris2rc2_to_u32(b)); }
IDRIS2RC2_Value *idris2rc2_mod_Bits64(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBits64(idris2rc2_to_u64(a) % idris2rc2_to_u64(b)); }

#define IDRIS2RC2_EUCLID_DIV(TY, CTY, GET, MK)                                     \
  IDRIS2RC2_Value *idris2rc2_div_##TY(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) {                      \
    CTY num = GET(a), denom = GET(b);                                       \
    CTY rem = num % denom;                                                   \
    return MK(num / denom + ((rem < 0) ? ((denom < 0) ? 1 : -1) : 0));       \
  }
#define IDRIS2RC2_EUCLID_MOD(TY, CTY, GET, MK)                                     \
  IDRIS2RC2_Value *idris2rc2_mod_##TY(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) {                      \
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

IDRIS2RC2_Value *idris2rc2_negate_Int8(IDRIS2RC2_Value *x) { return idris2rc2_mkInt8(-idris2rc2_to_i8(x)); }
IDRIS2RC2_Value *idris2rc2_negate_Int16(IDRIS2RC2_Value *x) { return idris2rc2_mkInt16(-idris2rc2_to_i16(x)); }
IDRIS2RC2_Value *idris2rc2_negate_Int32(IDRIS2RC2_Value *x) { return idris2rc2_mkInt32(-idris2rc2_to_i32(x)); }
IDRIS2RC2_Value *idris2rc2_negate_Int64(IDRIS2RC2_Value *x) { return idris2rc2_mkInt64(-idris2rc2_to_i64(x)); }
IDRIS2RC2_Value *idris2rc2_negate_Double(IDRIS2RC2_Value *x) { return idris2rc2_mkDouble(-idris2rc2_to_double(x)); }

// ---- Double ----
IDRIS2RC2_Value *idris2rc2_add_Double(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkDouble(idris2rc2_to_double(a) + idris2rc2_to_double(b)); }
IDRIS2RC2_Value *idris2rc2_sub_Double(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkDouble(idris2rc2_to_double(a) - idris2rc2_to_double(b)); }
IDRIS2RC2_Value *idris2rc2_mul_Double(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkDouble(idris2rc2_to_double(a) * idris2rc2_to_double(b)); }
IDRIS2RC2_Value *idris2rc2_div_Double(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkDouble(idris2rc2_to_double(a) / idris2rc2_to_double(b)); }
IDRIS2RC2_Value *idris2rc2_lt_Double(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBool(idris2rc2_to_double(a) < idris2rc2_to_double(b)); }
IDRIS2RC2_Value *idris2rc2_gt_Double(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBool(idris2rc2_to_double(a) > idris2rc2_to_double(b)); }
IDRIS2RC2_Value *idris2rc2_eq_Double(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBool(idris2rc2_to_double(a) == idris2rc2_to_double(b)); }
IDRIS2RC2_Value *idris2rc2_lte_Double(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBool(idris2rc2_to_double(a) <= idris2rc2_to_double(b)); }
IDRIS2RC2_Value *idris2rc2_gte_Double(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBool(idris2rc2_to_double(a) >= idris2rc2_to_double(b)); }

// ---- Char ----
IDRIS2RC2_Value *idris2rc2_lt_Char(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBool(idris2rc2_to_char(a) < idris2rc2_to_char(b)); }
IDRIS2RC2_Value *idris2rc2_gt_Char(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBool(idris2rc2_to_char(a) > idris2rc2_to_char(b)); }
IDRIS2RC2_Value *idris2rc2_eq_Char(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBool(idris2rc2_to_char(a) == idris2rc2_to_char(b)); }
IDRIS2RC2_Value *idris2rc2_lte_Char(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBool(idris2rc2_to_char(a) <= idris2rc2_to_char(b)); }
IDRIS2RC2_Value *idris2rc2_gte_Char(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBool(idris2rc2_to_char(a) >= idris2rc2_to_char(b)); }

// ---- string (byte-wise; matches RefC's simplification of the spec) ----
IDRIS2RC2_Value *idris2rc2_lt_string(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBool(strcmp(((IDRIS2RC2_String *)a)->str, ((IDRIS2RC2_String *)b)->str) < 0); }
IDRIS2RC2_Value *idris2rc2_gt_string(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBool(strcmp(((IDRIS2RC2_String *)a)->str, ((IDRIS2RC2_String *)b)->str) > 0); }
IDRIS2RC2_Value *idris2rc2_eq_string(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBool(strcmp(((IDRIS2RC2_String *)a)->str, ((IDRIS2RC2_String *)b)->str) == 0); }
IDRIS2RC2_Value *idris2rc2_lte_string(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBool(strcmp(((IDRIS2RC2_String *)a)->str, ((IDRIS2RC2_String *)b)->str) <= 0); }
IDRIS2RC2_Value *idris2rc2_gte_string(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBool(strcmp(((IDRIS2RC2_String *)a)->str, ((IDRIS2RC2_String *)b)->str) >= 0); }

// ---- Integer (arbitrary precision, via GMP) ----
IDRIS2RC2_Value *idris2rc2_add_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) { IDRIS2RC2_Integer *r = idris2rc2_mkInteger(); mpz_add(r->v, ((IDRIS2RC2_Integer *)x)->v, ((IDRIS2RC2_Integer *)y)->v); return (IDRIS2RC2_Value *)r; }
IDRIS2RC2_Value *idris2rc2_sub_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) { IDRIS2RC2_Integer *r = idris2rc2_mkInteger(); mpz_sub(r->v, ((IDRIS2RC2_Integer *)x)->v, ((IDRIS2RC2_Integer *)y)->v); return (IDRIS2RC2_Value *)r; }
IDRIS2RC2_Value *idris2rc2_mul_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) { IDRIS2RC2_Integer *r = idris2rc2_mkInteger(); mpz_mul(r->v, ((IDRIS2RC2_Integer *)x)->v, ((IDRIS2RC2_Integer *)y)->v); return (IDRIS2RC2_Value *)r; }
IDRIS2RC2_Value *idris2rc2_negate_Integer(IDRIS2RC2_Value *x) { IDRIS2RC2_Integer *r = idris2rc2_mkInteger(); mpz_neg(r->v, ((IDRIS2RC2_Integer *)x)->v); return (IDRIS2RC2_Value *)r; }
IDRIS2RC2_Value *idris2rc2_mod_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) { IDRIS2RC2_Integer *r = idris2rc2_mkInteger(); mpz_mod(r->v, ((IDRIS2RC2_Integer *)x)->v, ((IDRIS2RC2_Integer *)y)->v); return (IDRIS2RC2_Value *)r; }
IDRIS2RC2_Value *idris2rc2_div_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) {
  mpz_t rem, yq;
  mpz_inits(rem, yq, NULL);
  mpz_mod(rem, ((IDRIS2RC2_Integer *)x)->v, ((IDRIS2RC2_Integer *)y)->v);
  mpz_sub(yq, ((IDRIS2RC2_Integer *)x)->v, rem);
  IDRIS2RC2_Integer *r = idris2rc2_mkInteger();
  mpz_divexact(r->v, yq, ((IDRIS2RC2_Integer *)y)->v);
  mpz_clears(rem, yq, NULL);
  return (IDRIS2RC2_Value *)r;
}
IDRIS2RC2_Value *idris2rc2_shiftl_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) { IDRIS2RC2_Integer *r = idris2rc2_mkInteger(); mpz_mul_2exp(r->v, ((IDRIS2RC2_Integer *)x)->v, (mp_bitcnt_t)mpz_get_ui(((IDRIS2RC2_Integer *)y)->v)); return (IDRIS2RC2_Value *)r; }
IDRIS2RC2_Value *idris2rc2_shiftr_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) { IDRIS2RC2_Integer *r = idris2rc2_mkInteger(); mpz_fdiv_q_2exp(r->v, ((IDRIS2RC2_Integer *)x)->v, (mp_bitcnt_t)mpz_get_ui(((IDRIS2RC2_Integer *)y)->v)); return (IDRIS2RC2_Value *)r; }
IDRIS2RC2_Value *idris2rc2_and_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) { IDRIS2RC2_Integer *r = idris2rc2_mkInteger(); mpz_and(r->v, ((IDRIS2RC2_Integer *)x)->v, ((IDRIS2RC2_Integer *)y)->v); return (IDRIS2RC2_Value *)r; }
IDRIS2RC2_Value *idris2rc2_or_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) { IDRIS2RC2_Integer *r = idris2rc2_mkInteger(); mpz_ior(r->v, ((IDRIS2RC2_Integer *)x)->v, ((IDRIS2RC2_Integer *)y)->v); return (IDRIS2RC2_Value *)r; }
IDRIS2RC2_Value *idris2rc2_xor_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) { IDRIS2RC2_Integer *r = idris2rc2_mkInteger(); mpz_xor(r->v, ((IDRIS2RC2_Integer *)x)->v, ((IDRIS2RC2_Integer *)y)->v); return (IDRIS2RC2_Value *)r; }
IDRIS2RC2_Value *idris2rc2_lt_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) { return idris2rc2_mkBool(mpz_cmp(((IDRIS2RC2_Integer *)x)->v, ((IDRIS2RC2_Integer *)y)->v) < 0); }
IDRIS2RC2_Value *idris2rc2_gt_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) { return idris2rc2_mkBool(mpz_cmp(((IDRIS2RC2_Integer *)x)->v, ((IDRIS2RC2_Integer *)y)->v) > 0); }
IDRIS2RC2_Value *idris2rc2_eq_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) { return idris2rc2_mkBool(mpz_cmp(((IDRIS2RC2_Integer *)x)->v, ((IDRIS2RC2_Integer *)y)->v) == 0); }
IDRIS2RC2_Value *idris2rc2_lte_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) { return idris2rc2_mkBool(mpz_cmp(((IDRIS2RC2_Integer *)x)->v, ((IDRIS2RC2_Integer *)y)->v) <= 0); }
IDRIS2RC2_Value *idris2rc2_gte_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) { return idris2rc2_mkBool(mpz_cmp(((IDRIS2RC2_Integer *)x)->v, ((IDRIS2RC2_Integer *)y)->v) >= 0); }

// ---- casts ----

// Numeric-to-numeric: unbox as the source C type, truncate/convert to the
// destination C type (matching C's own conversion rules), box the result.
#define IDRIS2RC2_CAST_NUM(FROM, FCTY, FGET, FMK, TO, TCTY, TMK)                   \
  IDRIS2RC2_Value *idris2rc2_cast_##FROM##_to_##TO(IDRIS2RC2_Value *x) {                       \
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
  IDRIS2RC2_Value *idris2rc2_cast_##FROM##_to_Integer(IDRIS2RC2_Value *x) {        \
    IDRIS2RC2_Integer *r = idris2rc2_mkInteger();                                  \
    mpz_set_si(r->v, (long)FGET(x));                                               \
    return (IDRIS2RC2_Value *)r;                                                   \
  }
#define IDRIS2RC2_CAST_UNSIGNED_TO_INTEGER(FROM, FCTY, FGET, FMK)                  \
  IDRIS2RC2_Value *idris2rc2_cast_##FROM##_to_Integer(IDRIS2RC2_Value *x) {        \
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
  IDRIS2RC2_Value *idris2rc2_cast_##FROM##_to_Char(IDRIS2RC2_Value *x) {                       \
    return idris2rc2_mkChar((uint32_t)(uint8_t)FGET(x));                          \
  }
IDRIS2RC2_INTTYPES(IDRIS2RC2_CAST_TO_CHAR)

#define IDRIS2RC2_CAST_TO_STRING_SIGNED(FROM, FCTY, FGET, FMT)                     \
  IDRIS2RC2_Value *idris2rc2_cast_##FROM##_to_string(IDRIS2RC2_Value *x) {                     \
    FCTY v = FGET(x);                                                        \
    int l = snprintf(NULL, 0, FMT, v);                                       \
    IDRIS2RC2_String *r = idris2rc2_mkEmptyString((size_t)l + 1);                       \
    sprintf(r->str, FMT, v);                                                \
    return (IDRIS2RC2_Value *)r;                                                   \
  }
IDRIS2RC2_CAST_TO_STRING_SIGNED(Int8, int8_t, idris2rc2_to_i8, "%" PRId8)
IDRIS2RC2_CAST_TO_STRING_SIGNED(Int16, int16_t, idris2rc2_to_i16, "%" PRId16)
IDRIS2RC2_CAST_TO_STRING_SIGNED(Int32, int32_t, idris2rc2_to_i32, "%" PRId32)
IDRIS2RC2_CAST_TO_STRING_SIGNED(Int64, int64_t, idris2rc2_to_i64, "%" PRId64)
IDRIS2RC2_CAST_TO_STRING_SIGNED(Bits8, uint8_t, idris2rc2_to_u8, "%" PRIu8)
IDRIS2RC2_CAST_TO_STRING_SIGNED(Bits16, uint16_t, idris2rc2_to_u16, "%" PRIu16)
IDRIS2RC2_CAST_TO_STRING_SIGNED(Bits32, uint32_t, idris2rc2_to_u32, "%" PRIu32)
IDRIS2RC2_CAST_TO_STRING_SIGNED(Bits64, uint64_t, idris2rc2_to_u64, "%" PRIu64)

// ---- Double ----
IDRIS2RC2_Value *idris2rc2_cast_Double_to_Int8(IDRIS2RC2_Value *x) { return idris2rc2_mkInt8((int8_t)idris2rc2_to_double(x)); }
IDRIS2RC2_Value *idris2rc2_cast_Double_to_Int16(IDRIS2RC2_Value *x) { return idris2rc2_mkInt16((int16_t)idris2rc2_to_double(x)); }
IDRIS2RC2_Value *idris2rc2_cast_Double_to_Int32(IDRIS2RC2_Value *x) { return idris2rc2_mkInt32((int32_t)idris2rc2_to_double(x)); }
IDRIS2RC2_Value *idris2rc2_cast_Double_to_Int64(IDRIS2RC2_Value *x) { return idris2rc2_mkInt64((int64_t)idris2rc2_to_double(x)); }
IDRIS2RC2_Value *idris2rc2_cast_Double_to_Bits8(IDRIS2RC2_Value *x) { return idris2rc2_mkBits8((uint8_t)idris2rc2_to_double(x)); }
IDRIS2RC2_Value *idris2rc2_cast_Double_to_Bits16(IDRIS2RC2_Value *x) { return idris2rc2_mkBits16((uint16_t)idris2rc2_to_double(x)); }
IDRIS2RC2_Value *idris2rc2_cast_Double_to_Bits32(IDRIS2RC2_Value *x) { return idris2rc2_mkBits32((uint32_t)idris2rc2_to_double(x)); }
IDRIS2RC2_Value *idris2rc2_cast_Double_to_Bits64(IDRIS2RC2_Value *x) { return idris2rc2_mkBits64((uint64_t)idris2rc2_to_double(x)); }
IDRIS2RC2_Value *idris2rc2_cast_Double_to_Integer(IDRIS2RC2_Value *x) { IDRIS2RC2_Integer *r = idris2rc2_mkInteger(); mpz_set_d(r->v, idris2rc2_to_double(x)); return (IDRIS2RC2_Value *)r; }
IDRIS2RC2_Value *idris2rc2_cast_Double_to_Char(IDRIS2RC2_Value *x) { return idris2rc2_mkChar((uint32_t)(uint8_t)idris2rc2_to_double(x)); }
IDRIS2RC2_Value *idris2rc2_cast_Double_to_string(IDRIS2RC2_Value *x) {
  double v = idris2rc2_to_double(x);
  int l = snprintf(NULL, 0, "%f", v);
  IDRIS2RC2_String *r = idris2rc2_mkEmptyString((size_t)l + 1);
  sprintf(r->str, "%f", v);
  return (IDRIS2RC2_Value *)r;
}

// ---- Char ----
IDRIS2RC2_Value *idris2rc2_cast_Char_to_Int8(IDRIS2RC2_Value *x) { return idris2rc2_mkInt8((int8_t)idris2rc2_to_char(x)); }
IDRIS2RC2_Value *idris2rc2_cast_Char_to_Int16(IDRIS2RC2_Value *x) { return idris2rc2_mkInt16((int16_t)idris2rc2_to_char(x)); }
IDRIS2RC2_Value *idris2rc2_cast_Char_to_Int32(IDRIS2RC2_Value *x) { return idris2rc2_mkInt32((int32_t)idris2rc2_to_char(x)); }
IDRIS2RC2_Value *idris2rc2_cast_Char_to_Int64(IDRIS2RC2_Value *x) { return idris2rc2_mkInt64((int64_t)idris2rc2_to_char(x)); }
IDRIS2RC2_Value *idris2rc2_cast_Char_to_Bits8(IDRIS2RC2_Value *x) { return idris2rc2_mkBits8((uint8_t)idris2rc2_to_char(x)); }
IDRIS2RC2_Value *idris2rc2_cast_Char_to_Bits16(IDRIS2RC2_Value *x) { return idris2rc2_mkBits16((uint16_t)idris2rc2_to_char(x)); }
IDRIS2RC2_Value *idris2rc2_cast_Char_to_Bits32(IDRIS2RC2_Value *x) { return idris2rc2_mkBits32((uint32_t)idris2rc2_to_char(x)); }
IDRIS2RC2_Value *idris2rc2_cast_Char_to_Bits64(IDRIS2RC2_Value *x) { return idris2rc2_mkBits64((uint64_t)idris2rc2_to_char(x)); }
IDRIS2RC2_Value *idris2rc2_cast_Char_to_Integer(IDRIS2RC2_Value *x) { IDRIS2RC2_Integer *r = idris2rc2_mkInteger(); mpz_set_si(r->v, (long)idris2rc2_to_char(x)); return (IDRIS2RC2_Value *)r; }
IDRIS2RC2_Value *idris2rc2_cast_Char_to_string(IDRIS2RC2_Value *x) {
  // Encode the codepoint as UTF-8.
  uint32_t c = idris2rc2_to_char(x);
  char buf[5] = {0};
  int n;
  if (c < 0x80) { buf[0] = (char)c; n = 1; }
  else if (c < 0x800) { buf[0] = (char)(0xC0 | (c >> 6)); buf[1] = (char)(0x80 | (c & 0x3F)); n = 2; }
  else if (c < 0x10000) { buf[0] = (char)(0xE0 | (c >> 12)); buf[1] = (char)(0x80 | ((c >> 6) & 0x3F)); buf[2] = (char)(0x80 | (c & 0x3F)); n = 3; }
  else { buf[0] = (char)(0xF0 | (c >> 18)); buf[1] = (char)(0x80 | ((c >> 12) & 0x3F)); buf[2] = (char)(0x80 | ((c >> 6) & 0x3F)); buf[3] = (char)(0x80 | (c & 0x3F)); n = 4; }
  IDRIS2RC2_String *r = idris2rc2_mkEmptyString((size_t)n + 1);
  memcpy(r->str, buf, (size_t)n);
  return (IDRIS2RC2_Value *)r;
}

// ---- Integer ----
static uint64_t idris2rc2_mpz_lsb(mpz_t i, mp_bitcnt_t bits) {
  mpz_t r;
  mpz_init(r);
  mpz_fdiv_r_2exp(r, i, bits);
  uint64_t v = mpz_get_ui(r);
  mpz_clear(r);
  return v;
}
IDRIS2RC2_Value *idris2rc2_cast_Integer_to_Int8(IDRIS2RC2_Value *x) { return idris2rc2_mkInt8((int8_t)idris2rc2_mpz_lsb(((IDRIS2RC2_Integer *)x)->v, 8)); }
IDRIS2RC2_Value *idris2rc2_cast_Integer_to_Int16(IDRIS2RC2_Value *x) { return idris2rc2_mkInt16((int16_t)idris2rc2_mpz_lsb(((IDRIS2RC2_Integer *)x)->v, 16)); }
IDRIS2RC2_Value *idris2rc2_cast_Integer_to_Int32(IDRIS2RC2_Value *x) { return idris2rc2_mkInt32((int32_t)idris2rc2_mpz_lsb(((IDRIS2RC2_Integer *)x)->v, 32)); }
IDRIS2RC2_Value *idris2rc2_cast_Integer_to_Int64(IDRIS2RC2_Value *x) { return idris2rc2_mkInt64((int64_t)idris2rc2_mpz_lsb(((IDRIS2RC2_Integer *)x)->v, 64)); }
IDRIS2RC2_Value *idris2rc2_cast_Integer_to_Bits8(IDRIS2RC2_Value *x) { return idris2rc2_mkBits8((uint8_t)idris2rc2_mpz_lsb(((IDRIS2RC2_Integer *)x)->v, 8)); }
IDRIS2RC2_Value *idris2rc2_cast_Integer_to_Bits16(IDRIS2RC2_Value *x) { return idris2rc2_mkBits16((uint16_t)idris2rc2_mpz_lsb(((IDRIS2RC2_Integer *)x)->v, 16)); }
IDRIS2RC2_Value *idris2rc2_cast_Integer_to_Bits32(IDRIS2RC2_Value *x) { return idris2rc2_mkBits32((uint32_t)idris2rc2_mpz_lsb(((IDRIS2RC2_Integer *)x)->v, 32)); }
IDRIS2RC2_Value *idris2rc2_cast_Integer_to_Bits64(IDRIS2RC2_Value *x) { return idris2rc2_mkBits64((uint64_t)idris2rc2_mpz_lsb(((IDRIS2RC2_Integer *)x)->v, 64)); }
IDRIS2RC2_Value *idris2rc2_cast_Integer_to_Double(IDRIS2RC2_Value *x) { return idris2rc2_mkDouble(mpz_get_d(((IDRIS2RC2_Integer *)x)->v)); }
IDRIS2RC2_Value *idris2rc2_cast_Integer_to_Char(IDRIS2RC2_Value *x) { return idris2rc2_mkChar((uint32_t)idris2rc2_mpz_lsb(((IDRIS2RC2_Integer *)x)->v, 32)); }
IDRIS2RC2_Value *idris2rc2_cast_Integer_to_string(IDRIS2RC2_Value *x) {
  IDRIS2RC2_String *r = IDRIS2RC2_NEW(IDRIS2RC2_String);
  r->header.tag = IDRIS2RC2_TAG_STRING;
  r->str = mpz_get_str(NULL, 10, ((IDRIS2RC2_Integer *)x)->v);
  return (IDRIS2RC2_Value *)r;
}

// ---- string ----
IDRIS2RC2_Value *idris2rc2_cast_string_to_Int8(IDRIS2RC2_Value *x) { return idris2rc2_mkInt8((int8_t)atoi(((IDRIS2RC2_String *)x)->str)); }
IDRIS2RC2_Value *idris2rc2_cast_string_to_Int16(IDRIS2RC2_Value *x) { return idris2rc2_mkInt16((int16_t)atoi(((IDRIS2RC2_String *)x)->str)); }
IDRIS2RC2_Value *idris2rc2_cast_string_to_Int32(IDRIS2RC2_Value *x) { return idris2rc2_mkInt32((int32_t)atoi(((IDRIS2RC2_String *)x)->str)); }
IDRIS2RC2_Value *idris2rc2_cast_string_to_Int64(IDRIS2RC2_Value *x) { return idris2rc2_mkInt64((int64_t)atoll(((IDRIS2RC2_String *)x)->str)); }
IDRIS2RC2_Value *idris2rc2_cast_string_to_Bits8(IDRIS2RC2_Value *x) { return idris2rc2_mkBits8((uint8_t)atoi(((IDRIS2RC2_String *)x)->str)); }
IDRIS2RC2_Value *idris2rc2_cast_string_to_Bits16(IDRIS2RC2_Value *x) { return idris2rc2_mkBits16((uint16_t)atoi(((IDRIS2RC2_String *)x)->str)); }
IDRIS2RC2_Value *idris2rc2_cast_string_to_Bits32(IDRIS2RC2_Value *x) { return idris2rc2_mkBits32((uint32_t)atoi(((IDRIS2RC2_String *)x)->str)); }
IDRIS2RC2_Value *idris2rc2_cast_string_to_Bits64(IDRIS2RC2_Value *x) { return idris2rc2_mkBits64((uint64_t)atoll(((IDRIS2RC2_String *)x)->str)); }
IDRIS2RC2_Value *idris2rc2_cast_string_to_Double(IDRIS2RC2_Value *x) { return idris2rc2_mkDouble(atof(((IDRIS2RC2_String *)x)->str)); }
IDRIS2RC2_Value *idris2rc2_cast_string_to_Integer(IDRIS2RC2_Value *x) {
  IDRIS2RC2_Integer *r = idris2rc2_mkInteger();
  mpz_set_str(r->v, ((IDRIS2RC2_String *)x)->str, 10);
  return (IDRIS2RC2_Value *)r;
}
IDRIS2RC2_Value *idris2rc2_cast_string_to_Char(IDRIS2RC2_Value *x) {
  // Decode the first UTF-8 codepoint (matching the way strings are packed
  // by idris2rc2_cast_Char_to_string), rather than just the first byte.
  unsigned char const *s = (unsigned char const *)((IDRIS2RC2_String *)x)->str;
  if (s[0] == '\0')
    return idris2rc2_mkChar(0);
  uint32_t c;
  if ((s[0] & 0x80) == 0) c = s[0];
  else if ((s[0] & 0xE0) == 0xC0) c = ((s[0] & 0x1F) << 6) | (s[1] & 0x3F);
  else if ((s[0] & 0xF0) == 0xE0) c = ((s[0] & 0x0F) << 12) | ((s[1] & 0x3F) << 6) | (s[2] & 0x3F);
  else c = ((s[0] & 0x07) << 18) | ((s[1] & 0x3F) << 12) | ((s[2] & 0x3F) << 6) | (s[3] & 0x3F);
  return idris2rc2_mkChar(c);
}
