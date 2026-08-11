#pragma once

#include "datatypes.h"
#include "memory.h"
#include <math.h>

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

#define IDRIS2RC2_ADD_DECL(TY, CTY, GET, MK) IDRIS2RC2_Value *idris2rc2_add_##TY(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
#define IDRIS2RC2_SUB_DECL(TY, CTY, GET, MK) IDRIS2RC2_Value *idris2rc2_sub_##TY(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
#define IDRIS2RC2_MUL_DECL(TY, CTY, GET, MK) IDRIS2RC2_Value *idris2rc2_mul_##TY(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
#define IDRIS2RC2_SHL_DECL(TY, CTY, GET, MK) IDRIS2RC2_Value *idris2rc2_shiftl_##TY(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
#define IDRIS2RC2_SHR_DECL(TY, CTY, GET, MK) IDRIS2RC2_Value *idris2rc2_shiftr_##TY(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
#define IDRIS2RC2_AND_DECL(TY, CTY, GET, MK) IDRIS2RC2_Value *idris2rc2_and_##TY(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
#define IDRIS2RC2_OR_DECL(TY, CTY, GET, MK) IDRIS2RC2_Value *idris2rc2_or_##TY(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
#define IDRIS2RC2_XOR_DECL(TY, CTY, GET, MK) IDRIS2RC2_Value *idris2rc2_xor_##TY(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
#define IDRIS2RC2_DIV_DECL(TY, CTY, GET, MK) IDRIS2RC2_Value *idris2rc2_div_##TY(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
#define IDRIS2RC2_MOD_DECL(TY, CTY, GET, MK) IDRIS2RC2_Value *idris2rc2_mod_##TY(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
#define IDRIS2RC2_LT_DECL(TY, CTY, GET, MK) IDRIS2RC2_Value *idris2rc2_lt_##TY(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
#define IDRIS2RC2_GT_DECL(TY, CTY, GET, MK) IDRIS2RC2_Value *idris2rc2_gt_##TY(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
#define IDRIS2RC2_EQ_DECL(TY, CTY, GET, MK) IDRIS2RC2_Value *idris2rc2_eq_##TY(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
#define IDRIS2RC2_LTE_DECL(TY, CTY, GET, MK) IDRIS2RC2_Value *idris2rc2_lte_##TY(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
#define IDRIS2RC2_GTE_DECL(TY, CTY, GET, MK) IDRIS2RC2_Value *idris2rc2_gte_##TY(IDRIS2RC2_Value *, IDRIS2RC2_Value *);

IDRIS2RC2_INTTYPES(IDRIS2RC2_ADD_DECL)
IDRIS2RC2_INTTYPES(IDRIS2RC2_SUB_DECL)
IDRIS2RC2_INTTYPES(IDRIS2RC2_MUL_DECL)
IDRIS2RC2_INTTYPES(IDRIS2RC2_SHL_DECL)
IDRIS2RC2_INTTYPES(IDRIS2RC2_SHR_DECL)
IDRIS2RC2_INTTYPES(IDRIS2RC2_AND_DECL)
IDRIS2RC2_INTTYPES(IDRIS2RC2_OR_DECL)
IDRIS2RC2_INTTYPES(IDRIS2RC2_XOR_DECL)
IDRIS2RC2_INTTYPES(IDRIS2RC2_DIV_DECL)
IDRIS2RC2_INTTYPES(IDRIS2RC2_MOD_DECL)
IDRIS2RC2_INTTYPES(IDRIS2RC2_LT_DECL)
IDRIS2RC2_INTTYPES(IDRIS2RC2_GT_DECL)
IDRIS2RC2_INTTYPES(IDRIS2RC2_EQ_DECL)
IDRIS2RC2_INTTYPES(IDRIS2RC2_LTE_DECL)
IDRIS2RC2_INTTYPES(IDRIS2RC2_GTE_DECL)

IDRIS2RC2_Value *idris2rc2_negate_Int8(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_negate_Int16(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_negate_Int32(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_negate_Int64(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_negate_Double(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_negate_Integer(IDRIS2RC2_Value *);

IDRIS2RC2_Value *idris2rc2_add_Double(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_sub_Double(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_mul_Double(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_div_Double(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_lt_Double(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_gt_Double(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_eq_Double(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_lte_Double(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_gte_Double(IDRIS2RC2_Value *, IDRIS2RC2_Value *);

IDRIS2RC2_Value *idris2rc2_lt_Char(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_gt_Char(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_eq_Char(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_lte_Char(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_gte_Char(IDRIS2RC2_Value *, IDRIS2RC2_Value *);

IDRIS2RC2_Value *idris2rc2_lt_string(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_gt_string(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_eq_string(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_lte_string(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_gte_string(IDRIS2RC2_Value *, IDRIS2RC2_Value *);

IDRIS2RC2_Value *idris2rc2_add_Integer(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_sub_Integer(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_mul_Integer(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_div_Integer(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_mod_Integer(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_shiftl_Integer(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_shiftr_Integer(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_and_Integer(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_or_Integer(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_xor_Integer(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_lt_Integer(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_gt_Integer(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_eq_Integer(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_lte_Integer(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_gte_Integer(IDRIS2RC2_Value *, IDRIS2RC2_Value *);

// Casts. Naming: idris2rc2_cast_<From>_to_<To>. Only the combinations actually
// referenced by a compiled program need to resolve at link time, so this
// covers the full numeric matrix plus Integer/Double/Char/string boundary
// conversions (matching what Idris2's Prelude actually exposes as `cast`).
#define IDRIS2RC2_CAST_DECL(FROM, FCTY, FGET, FMK)                                 \
  IDRIS2RC2_Value *idris2rc2_cast_##FROM##_to_Int8(IDRIS2RC2_Value *);                         \
  IDRIS2RC2_Value *idris2rc2_cast_##FROM##_to_Int16(IDRIS2RC2_Value *);                        \
  IDRIS2RC2_Value *idris2rc2_cast_##FROM##_to_Int32(IDRIS2RC2_Value *);                        \
  IDRIS2RC2_Value *idris2rc2_cast_##FROM##_to_Int64(IDRIS2RC2_Value *);                        \
  IDRIS2RC2_Value *idris2rc2_cast_##FROM##_to_Bits8(IDRIS2RC2_Value *);                        \
  IDRIS2RC2_Value *idris2rc2_cast_##FROM##_to_Bits16(IDRIS2RC2_Value *);                       \
  IDRIS2RC2_Value *idris2rc2_cast_##FROM##_to_Bits32(IDRIS2RC2_Value *);                       \
  IDRIS2RC2_Value *idris2rc2_cast_##FROM##_to_Bits64(IDRIS2RC2_Value *);                       \
  IDRIS2RC2_Value *idris2rc2_cast_##FROM##_to_Double(IDRIS2RC2_Value *);                       \
  IDRIS2RC2_Value *idris2rc2_cast_##FROM##_to_Integer(IDRIS2RC2_Value *);                      \
  IDRIS2RC2_Value *idris2rc2_cast_##FROM##_to_Char(IDRIS2RC2_Value *);                         \
  IDRIS2RC2_Value *idris2rc2_cast_##FROM##_to_string(IDRIS2RC2_Value *);

IDRIS2RC2_INTTYPES(IDRIS2RC2_CAST_DECL)

IDRIS2RC2_Value *idris2rc2_cast_Double_to_Int8(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_Double_to_Int16(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_Double_to_Int32(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_Double_to_Int64(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_Double_to_Bits8(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_Double_to_Bits16(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_Double_to_Bits32(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_Double_to_Bits64(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_Double_to_Integer(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_Double_to_Char(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_Double_to_string(IDRIS2RC2_Value *);

IDRIS2RC2_Value *idris2rc2_cast_Char_to_Int8(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_Char_to_Int16(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_Char_to_Int32(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_Char_to_Int64(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_Char_to_Bits8(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_Char_to_Bits16(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_Char_to_Bits32(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_Char_to_Bits64(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_Char_to_Integer(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_Char_to_string(IDRIS2RC2_Value *);

IDRIS2RC2_Value *idris2rc2_cast_Integer_to_Int8(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_Integer_to_Int16(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_Integer_to_Int32(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_Integer_to_Int64(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_Integer_to_Bits8(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_Integer_to_Bits16(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_Integer_to_Bits32(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_Integer_to_Bits64(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_Integer_to_Double(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_Integer_to_Char(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_Integer_to_string(IDRIS2RC2_Value *);

IDRIS2RC2_Value *idris2rc2_cast_string_to_Int8(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_string_to_Int16(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_string_to_Int32(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_string_to_Int64(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_string_to_Bits8(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_string_to_Bits16(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_string_to_Bits32(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_string_to_Bits64(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_string_to_Double(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_string_to_Integer(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_string_to_Char(IDRIS2RC2_Value *); // first UTF-8 codepoint, or NUL for ""
