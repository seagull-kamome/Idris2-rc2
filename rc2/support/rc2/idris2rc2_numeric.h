#pragma once

#include "idris2rc2_datatypes.h"
#include "idris2rc2_memory.h"
#include "idris2rc2_rt.h"
#include <math.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <float.h>

// `Data.Double`'s upstream `unitRoundoff`/`epsilon`/`nan`/`inf` carry only
// `"scheme:..."`/`"node:..."` %foreign tags -- unusable on refc/rc2 at
// all (TODO.md's "Upstream stdlib `%foreign` declarations with no C/RefC
// backend at all"). `Data.Double.RC2` (libs/rc2base) patches all four via
// `%foreign_impl` onto these. Values matched against
// idris2-src/support/chez/support.ss's own definitions rather than
// assumed: `blodwen-calcFlonumUnitRoundoff` halves from 1.0 until
// `1.0 + uro == 1.0` first holds and returns that uro -- for IEEE 754
// binary64 this is provably exactly DBL_EPSILON/2 (the classic round-to-
// nearest-even boundary), and `blodwen-calcFlonumEpsilon` is defined as
// exactly double that, i.e. DBL_EPSILON itself.
static inline double idris2rc2_unitRoundoff(void) { return DBL_EPSILON / 2.0; }
static inline double idris2rc2_epsilon(void) { return DBL_EPSILON; }
static inline double idris2rc2_nan(void) { return NAN; }
static inline double idris2rc2_inf(void) { return INFINITY; }

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

// Subset of IDRIS2RC2_INTTYPES that's always a tagged pointer
// (Types.alwaysUnboxed) at the C level, never a real heap allocation --
// idris2rc2_isUnique (a raw ->header.refCount read) would be undefined
// behaviour on one of these, so the reuse-in-place arithmetic below
// (IDRIS2RC2_INTTYPES_REUSABLE) must never be applied to them. Also
// covered by the alwaysUnboxed dup/drop elision already (Compiler.RC2.RC's
// alwaysUnboxedBoxedLocalsR), so there's no drop call left to reuse
// anyway for these.
#define IDRIS2RC2_INTTYPES_TAGGED(F)                                              \
  F(Int8, int8_t, idris2rc2_to_i8, idris2rc2_mkInt8)                                     \
  F(Int16, int16_t, idris2rc2_to_i16, idris2rc2_mkInt16)                                 \
  F(Int32, int32_t, idris2rc2_to_i32, idris2rc2_mkInt32)                                 \
  F(Bits8, uint8_t, idris2rc2_to_u8, idris2rc2_mkBits8)                                  \
  F(Bits16, uint16_t, idris2rc2_to_u16, idris2rc2_mkBits16)                              \
  F(Bits32, uint32_t, idris2rc2_to_u32, idris2rc2_mkBits32)

// The other subset: genuinely heap-allocated (outside the small-int
// cache) when Boxed, so a dying/unique operand's own storage is worth
// reusing in place -- see rc2/doc/rop-reuse.md.
#define IDRIS2RC2_INTTYPES_REUSABLE(F)                                            \
  F(Int64, int64_t, idris2rc2_to_i64, idris2rc2_mkInt64)                                 \
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

// Idris shifts act on the unbounded integer and truncate it to the type, as
// Chez's `ash` does: a count of the type's width or more gives 0, or -1 when
// a negative value is shifted right. C leaves such shifts undefined (x86
// masks the count), and shifts a negative value left undefined too, hence
// the unsigned detour. Used by native and boxed shifts alike.
#define IDRIS2RC2_SHIFTS_UNSIGNED(TY, CTY, BITS)                                  \
  static inline CTY idris2rc2_shl_##TY(CTY x, uint64_t y) {                   \
    return y >= BITS ? (CTY)0 : (CTY)((uint64_t)x << y);                      \
  }                                                                           \
  static inline CTY idris2rc2_shr_##TY(CTY x, uint64_t y) {                   \
    return y >= BITS ? (CTY)0 : (CTY)(x >> y);                                \
  }
#define IDRIS2RC2_SHIFTS_SIGNED(TY, CTY, BITS)                                    \
  static inline CTY idris2rc2_shl_##TY(CTY x, uint64_t y) {                   \
    return y >= BITS ? (CTY)0 : (CTY)((uint64_t)x << y);                      \
  }                                                                           \
  static inline CTY idris2rc2_shr_##TY(CTY x, uint64_t y) {                   \
    return y >= BITS ? (CTY)(x < 0 ? -1 : 0) : (CTY)(x >> y);                 \
  }
IDRIS2RC2_SHIFTS_SIGNED(Int8, int8_t, 8)
IDRIS2RC2_SHIFTS_SIGNED(Int16, int16_t, 16)
IDRIS2RC2_SHIFTS_SIGNED(Int32, int32_t, 32)
IDRIS2RC2_SHIFTS_SIGNED(Int64, int64_t, 64)
IDRIS2RC2_SHIFTS_UNSIGNED(Bits8, uint8_t, 8)
IDRIS2RC2_SHIFTS_UNSIGNED(Bits16, uint16_t, 16)
IDRIS2RC2_SHIFTS_UNSIGNED(Bits32, uint32_t, 32)
IDRIS2RC2_SHIFTS_UNSIGNED(Bits64, uint64_t, 64)

// ---- fixed-width integer arithmetic/bitwise ops (wrapping, matching C's
//      own overflow behaviour for the underlying width) ----

#define IDRIS2RC2_DEFOP(OPNAME, TY, CTY, GET, MK, OP)                              \
  static inline IDRIS2RC2_Value *idris2rc2_##OPNAME##_##TY(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) {  \
    return MK((CTY)(GET(a) OP GET(b)));                                     \
  }

#define IDRIS2RC2_ADD_DEF(TY, CTY, GET, MK) IDRIS2RC2_DEFOP(add, TY, CTY, GET, MK, +)
#define IDRIS2RC2_SUB_DEF(TY, CTY, GET, MK) IDRIS2RC2_DEFOP(sub, TY, CTY, GET, MK, -)
#define IDRIS2RC2_MUL_DEF(TY, CTY, GET, MK) IDRIS2RC2_DEFOP(mul, TY, CTY, GET, MK, *)
#define IDRIS2RC2_DEFSHIFT(OPNAME, FN, TY, CTY, GET, MK)                            \
  static inline IDRIS2RC2_Value *idris2rc2_##OPNAME##_##TY(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) {  \
    return MK(idris2rc2_##FN##_##TY(GET(a), (uint64_t)GET(b)));             \
  }
#define IDRIS2RC2_SHL_DEF(TY, CTY, GET, MK) IDRIS2RC2_DEFSHIFT(shiftl, shl, TY, CTY, GET, MK)
#define IDRIS2RC2_SHR_DEF(TY, CTY, GET, MK) IDRIS2RC2_DEFSHIFT(shiftr, shr, TY, CTY, GET, MK)
#define IDRIS2RC2_AND_DEF(TY, CTY, GET, MK) IDRIS2RC2_DEFOP(and, TY, CTY, GET, MK, &)
#define IDRIS2RC2_OR_DEF(TY, CTY, GET, MK) IDRIS2RC2_DEFOP(or, TY, CTY, GET, MK, |)
#define IDRIS2RC2_XOR_DEF(TY, CTY, GET, MK) IDRIS2RC2_DEFOP(xor, TY, CTY, GET, MK, ^)

IDRIS2RC2_INTTYPES_TAGGED(IDRIS2RC2_ADD_DEF)
IDRIS2RC2_INTTYPES_TAGGED(IDRIS2RC2_SUB_DEF)
IDRIS2RC2_INTTYPES_TAGGED(IDRIS2RC2_MUL_DEF)
IDRIS2RC2_INTTYPES_TAGGED(IDRIS2RC2_SHL_DEF)
IDRIS2RC2_INTTYPES_TAGGED(IDRIS2RC2_SHR_DEF)
IDRIS2RC2_INTTYPES_TAGGED(IDRIS2RC2_AND_DEF)
IDRIS2RC2_INTTYPES_TAGGED(IDRIS2RC2_OR_DEF)
IDRIS2RC2_INTTYPES_TAGGED(IDRIS2RC2_XOR_DEF)

// Int64/Bits64: reuse-consuming versions -- both operands are handed
// over already dup'd for any use past this call (Compiler.RC2.Emit's
// ROp lowering, matching Integer's own treatment -- see
// rc2/doc/rop-reuse.md), so a uniquely-referenced one's own struct
// becomes the result in place instead of a fresh idris2rc2_mk*; the
// other operand is dropped here instead of by the caller.
#define IDRIS2RC2_DEFOP_REUSE(OPNAME, TY, CTY, GET, MK, OP)                        \
  static inline IDRIS2RC2_Value *idris2rc2_##OPNAME##_##TY(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { \
    CTY result = (CTY)(GET(a) OP GET(b));                                   \
    IDRIS2RC2_Value *dst;                                                    \
    if (idris2rc2_isUnique(a))      { ((IDRIS2RC2_##TY *)a)->v = result; dst = a; idris2rc2_drop(b); } \
    else if (idris2rc2_isUnique(b)) { ((IDRIS2RC2_##TY *)b)->v = result; dst = b; idris2rc2_drop(a); } \
    else                             { dst = MK(result); idris2rc2_drop(a); idris2rc2_drop(b); }        \
    return dst;                                                              \
  }
#define IDRIS2RC2_ADD_REUSE_DEF(TY, CTY, GET, MK) IDRIS2RC2_DEFOP_REUSE(add, TY, CTY, GET, MK, +)
#define IDRIS2RC2_SUB_REUSE_DEF(TY, CTY, GET, MK) IDRIS2RC2_DEFOP_REUSE(sub, TY, CTY, GET, MK, -)
#define IDRIS2RC2_MUL_REUSE_DEF(TY, CTY, GET, MK) IDRIS2RC2_DEFOP_REUSE(mul, TY, CTY, GET, MK, *)
#define IDRIS2RC2_DEFSHIFT_REUSE(OPNAME, FN, TY, CTY, GET, MK)                      \
  static inline IDRIS2RC2_Value *idris2rc2_##OPNAME##_##TY(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { \
    CTY result = idris2rc2_##FN##_##TY(GET(a), (uint64_t)GET(b));           \
    IDRIS2RC2_Value *dst;                                                    \
    if (idris2rc2_isUnique(a))      { ((IDRIS2RC2_##TY *)a)->v = result; dst = a; idris2rc2_drop(b); } \
    else if (idris2rc2_isUnique(b)) { ((IDRIS2RC2_##TY *)b)->v = result; dst = b; idris2rc2_drop(a); } \
    else                             { dst = MK(result); idris2rc2_drop(a); idris2rc2_drop(b); }        \
    return dst;                                                              \
  }
#define IDRIS2RC2_SHL_REUSE_DEF(TY, CTY, GET, MK) IDRIS2RC2_DEFSHIFT_REUSE(shiftl, shl, TY, CTY, GET, MK)
#define IDRIS2RC2_SHR_REUSE_DEF(TY, CTY, GET, MK) IDRIS2RC2_DEFSHIFT_REUSE(shiftr, shr, TY, CTY, GET, MK)
#define IDRIS2RC2_AND_REUSE_DEF(TY, CTY, GET, MK) IDRIS2RC2_DEFOP_REUSE(and, TY, CTY, GET, MK, &)
#define IDRIS2RC2_OR_REUSE_DEF(TY, CTY, GET, MK) IDRIS2RC2_DEFOP_REUSE(or, TY, CTY, GET, MK, |)
#define IDRIS2RC2_XOR_REUSE_DEF(TY, CTY, GET, MK) IDRIS2RC2_DEFOP_REUSE(xor, TY, CTY, GET, MK, ^)

IDRIS2RC2_INTTYPES_REUSABLE(IDRIS2RC2_ADD_REUSE_DEF)
IDRIS2RC2_INTTYPES_REUSABLE(IDRIS2RC2_SUB_REUSE_DEF)
IDRIS2RC2_INTTYPES_REUSABLE(IDRIS2RC2_MUL_REUSE_DEF)
IDRIS2RC2_INTTYPES_REUSABLE(IDRIS2RC2_SHL_REUSE_DEF)
IDRIS2RC2_INTTYPES_REUSABLE(IDRIS2RC2_SHR_REUSE_DEF)
IDRIS2RC2_INTTYPES_REUSABLE(IDRIS2RC2_AND_REUSE_DEF)
IDRIS2RC2_INTTYPES_REUSABLE(IDRIS2RC2_OR_REUSE_DEF)
IDRIS2RC2_INTTYPES_REUSABLE(IDRIS2RC2_XOR_REUSE_DEF)

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

// Bits64: reuse-consuming, same pattern as the arithmetic/bitwise ops
// above -- see rc2/doc/rop-reuse.md.
static inline IDRIS2RC2_Value *idris2rc2_div_Bits64(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) {
  uint64_t result = idris2rc2_to_u64(a) / idris2rc2_to_u64(b);
  IDRIS2RC2_Value *dst;
  if (idris2rc2_isUnique(a))      { ((IDRIS2RC2_Bits64 *)a)->v = result; dst = a; idris2rc2_drop(b); }
  else if (idris2rc2_isUnique(b)) { ((IDRIS2RC2_Bits64 *)b)->v = result; dst = b; idris2rc2_drop(a); }
  else                             { dst = idris2rc2_mkBits64(result); idris2rc2_drop(a); idris2rc2_drop(b); }
  return dst;
}
static inline IDRIS2RC2_Value *idris2rc2_mod_Bits8(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBits8(idris2rc2_to_u8(a) % idris2rc2_to_u8(b)); }
static inline IDRIS2RC2_Value *idris2rc2_mod_Bits16(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBits16(idris2rc2_to_u16(a) % idris2rc2_to_u16(b)); }
static inline IDRIS2RC2_Value *idris2rc2_mod_Bits32(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBits32(idris2rc2_to_u32(a) % idris2rc2_to_u32(b)); }
static inline IDRIS2RC2_Value *idris2rc2_mod_Bits64(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) {
  uint64_t result = idris2rc2_to_u64(a) % idris2rc2_to_u64(b);
  IDRIS2RC2_Value *dst;
  if (idris2rc2_isUnique(a))      { ((IDRIS2RC2_Bits64 *)a)->v = result; dst = a; idris2rc2_drop(b); }
  else if (idris2rc2_isUnique(b)) { ((IDRIS2RC2_Bits64 *)b)->v = result; dst = b; idris2rc2_drop(a); }
  else                             { dst = idris2rc2_mkBits64(result); idris2rc2_drop(a); idris2rc2_drop(b); }
  return dst;
}

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
IDRIS2RC2_EUCLID_MOD(Int8, int8_t, idris2rc2_to_i8, idris2rc2_mkInt8)
IDRIS2RC2_EUCLID_MOD(Int16, int16_t, idris2rc2_to_i16, idris2rc2_mkInt16)
IDRIS2RC2_EUCLID_MOD(Int32, int32_t, idris2rc2_to_i32, idris2rc2_mkInt32)

// Int64: reuse-consuming Euclidean div/mod -- same pattern as the
// arithmetic/bitwise ops above -- see rc2/doc/rop-reuse.md.
static inline IDRIS2RC2_Value *idris2rc2_div_Int64(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) {
  int64_t num = idris2rc2_to_i64(a), denom = idris2rc2_to_i64(b);
  int64_t rem = num % denom;
  int64_t result = num / denom + ((rem < 0) ? ((denom < 0) ? 1 : -1) : 0);
  IDRIS2RC2_Value *dst;
  if (idris2rc2_isUnique(a))      { ((IDRIS2RC2_Int64 *)a)->v = result; dst = a; idris2rc2_drop(b); }
  else if (idris2rc2_isUnique(b)) { ((IDRIS2RC2_Int64 *)b)->v = result; dst = b; idris2rc2_drop(a); }
  else                             { dst = idris2rc2_mkInt64(result); idris2rc2_drop(a); idris2rc2_drop(b); }
  return dst;
}
static inline IDRIS2RC2_Value *idris2rc2_mod_Int64(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) {
  int64_t num = idris2rc2_to_i64(a), denom = idris2rc2_to_i64(b);
  denom = (denom < 0) ? -denom : denom;
  int64_t result = num % denom + (num < 0 ? denom : 0);
  IDRIS2RC2_Value *dst;
  if (idris2rc2_isUnique(a))      { ((IDRIS2RC2_Int64 *)a)->v = result; dst = a; idris2rc2_drop(b); }
  else if (idris2rc2_isUnique(b)) { ((IDRIS2RC2_Int64 *)b)->v = result; dst = b; idris2rc2_drop(a); }
  else                             { dst = idris2rc2_mkInt64(result); idris2rc2_drop(a); idris2rc2_drop(b); }
  return dst;
}

static inline IDRIS2RC2_Value *idris2rc2_negate_Int8(IDRIS2RC2_Value *x) { return idris2rc2_mkInt8(-idris2rc2_to_i8(x)); }
static inline IDRIS2RC2_Value *idris2rc2_negate_Int16(IDRIS2RC2_Value *x) { return idris2rc2_mkInt16(-idris2rc2_to_i16(x)); }
static inline IDRIS2RC2_Value *idris2rc2_negate_Int32(IDRIS2RC2_Value *x) { return idris2rc2_mkInt32(-idris2rc2_to_i32(x)); }
// Int64/Double negate: reuse-consuming, unary version of the same
// pattern -- see rc2/doc/rop-reuse.md.
static inline IDRIS2RC2_Value *idris2rc2_negate_Int64(IDRIS2RC2_Value *x) {
  int64_t result = -idris2rc2_to_i64(x);
  if (idris2rc2_isUnique(x)) { ((IDRIS2RC2_Int64 *)x)->v = result; return x; }
  idris2rc2_drop(x);
  return idris2rc2_mkInt64(result);
}
static inline IDRIS2RC2_Value *idris2rc2_negate_Double(IDRIS2RC2_Value *x) {
  double result = -idris2rc2_to_double(x);
  if (idris2rc2_isUnique(x)) { ((IDRIS2RC2_Double *)x)->v = result; return x; }
  idris2rc2_drop(x);
  return idris2rc2_mkDouble(result);
}

// ---- Double ----
// Double: reuse-consuming -- never small-int-cached (idris2rc2_mkDouble
// always allocates), so every Boxed Double is a genuine heap struct
// worth reusing when unique -- see rc2/doc/rop-reuse.md.
#define IDRIS2RC2_DOUBLE_BINOP(OPNAME, OP)                                         \
  static inline IDRIS2RC2_Value *idris2rc2_##OPNAME##_Double(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { \
    double result = idris2rc2_to_double(a) OP idris2rc2_to_double(b);       \
    IDRIS2RC2_Value *dst;                                                    \
    if (idris2rc2_isUnique(a))      { ((IDRIS2RC2_Double *)a)->v = result; dst = a; idris2rc2_drop(b); } \
    else if (idris2rc2_isUnique(b)) { ((IDRIS2RC2_Double *)b)->v = result; dst = b; idris2rc2_drop(a); } \
    else                             { dst = idris2rc2_mkDouble(result); idris2rc2_drop(a); idris2rc2_drop(b); } \
    return dst;                                                              \
  }
IDRIS2RC2_DOUBLE_BINOP(add, +)
IDRIS2RC2_DOUBLE_BINOP(sub, -)
IDRIS2RC2_DOUBLE_BINOP(mul, *)
IDRIS2RC2_DOUBLE_BINOP(div, /)
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
// module note there); only these bare comparison wrappers are one-liners.
//
// Length-then-memcmp, not strcmp: a String's byte content may contain an
// embedded NUL (datatypes.h), which strcmp would treat as an early
// terminator. Ties on the shared prefix fall back to length, matching
// strcmp's own convention that a proper prefix sorts before its
// extension (a NUL byte -- absent past the shorter string's own end --
// would otherwise have sorted lower than any real content byte there).
static inline int idris2rc2_strcmp3(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) {
  IDRIS2RC2_String *sa = (IDRIS2RC2_String *)a, *sb = (IDRIS2RC2_String *)b;
  size_t n = sa->len < sb->len ? sa->len : sb->len;
  int c = n ? memcmp(sa->str, sb->str, n) : 0;
  if (c != 0) return c;
  return (sa->len > sb->len) - (sa->len < sb->len);
}
static inline IDRIS2RC2_Value *idris2rc2_lt_string(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBool(idris2rc2_strcmp3(a, b) < 0); }
static inline IDRIS2RC2_Value *idris2rc2_gt_string(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBool(idris2rc2_strcmp3(a, b) > 0); }
static inline IDRIS2RC2_Value *idris2rc2_eq_string(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) {
  IDRIS2RC2_String *sa = (IDRIS2RC2_String *)a, *sb = (IDRIS2RC2_String *)b;
  return idris2rc2_mkBool(sa->len == sb->len && (sa->len == 0 || memcmp(sa->str, sb->str, sa->len) == 0));
}
static inline IDRIS2RC2_Value *idris2rc2_lte_string(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBool(idris2rc2_strcmp3(a, b) <= 0); }
static inline IDRIS2RC2_Value *idris2rc2_gte_string(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) { return idris2rc2_mkBool(idris2rc2_strcmp3(a, b) >= 0); }

// ---- Integer (arbitrary precision, via GMP) ----
// Both operands immediate: plain int64_t arithmetic. Otherwise GMP, with
// an immediate operand read through idris2rc2_integerView; the result is
// normalized back to an immediate when it fits (rc2/doc/immediate-ints.md).
// The slow paths live in numeric.c.
//
// Add/Sub/Mul/Mod/And/Or/Xor/ShiftL/ShiftR/Neg consume both operands
// (rc2/doc/rop-reuse.md): a uniquely referenced boxed operand's mpz
// becomes the result in place.
#define idris2rc2_integer_both_imm(x, y) ((uintptr_t)(x) & (uintptr_t)(y) & 1)

typedef void (*idris2rc2_mpz_binop)(mpz_ptr, mpz_srcptr, mpz_srcptr);
IDRIS2RC2_Value *idris2rc2_integerBinopSlow(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y, idris2rc2_mpz_binop fn);
IDRIS2RC2_Value *idris2rc2_integerShiftSlow(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y, int left);
IDRIS2RC2_Value *idris2rc2_integerNegateSlow(IDRIS2RC2_Value *x);
int idris2rc2_integerCmpSlow(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y);
int idris2rc2_integerEqualsLiteral(IDRIS2RC2_Value *x, char const *digits);
double idris2rc2_integerToDoubleSlow(IDRIS2RC2_Value *x);

static inline IDRIS2RC2_Value *idris2rc2_add_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) {
  if (idris2rc2_integer_both_imm(x, y))
    return idris2rc2_mkIntegerI64(idris2rc2_imm_signed(x) + idris2rc2_imm_signed(y));
  return idris2rc2_integerBinopSlow(x, y, mpz_add);
}
static inline IDRIS2RC2_Value *idris2rc2_sub_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) {
  if (idris2rc2_integer_both_imm(x, y))
    return idris2rc2_mkIntegerI64(idris2rc2_imm_signed(x) - idris2rc2_imm_signed(y));
  return idris2rc2_integerBinopSlow(x, y, mpz_sub);
}
static inline IDRIS2RC2_Value *idris2rc2_mul_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) {
  int64_t r;
  if (idris2rc2_integer_both_imm(x, y) &&
      !__builtin_mul_overflow(idris2rc2_imm_signed(x), idris2rc2_imm_signed(y), &r))
    return idris2rc2_mkIntegerI64(r);
  return idris2rc2_integerBinopSlow(x, y, mpz_mul);
}
// mpz_mod: the remainder is never negative, whatever the divisor's sign.
static inline IDRIS2RC2_Value *idris2rc2_mod_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) {
  if (idris2rc2_integer_both_imm(x, y) && idris2rc2_imm_signed(y) != 0) {
    int64_t b = idris2rc2_imm_signed(y);
    int64_t r = idris2rc2_imm_signed(x) % b;
    return IDRIS2RC2_IMM_INT64(r < 0 ? r + (b < 0 ? -b : b) : r);
  }
  return idris2rc2_integerBinopSlow(x, y, mpz_mod);
}
#define IDRIS2RC2_INTEGER_BITOP(OPNAME, OP, MPZFN)                                 \
  static inline IDRIS2RC2_Value *idris2rc2_##OPNAME##_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) { \
    if (idris2rc2_integer_both_imm(x, y))                                         \
      return IDRIS2RC2_IMM_INT64(idris2rc2_imm_signed(x) OP idris2rc2_imm_signed(y)); \
    return idris2rc2_integerBinopSlow(x, y, MPZFN);                               \
  }
IDRIS2RC2_INTEGER_BITOP(and, &, mpz_and)
IDRIS2RC2_INTEGER_BITOP(or, |, mpz_ior)
IDRIS2RC2_INTEGER_BITOP(xor, ^, mpz_xor)

static inline IDRIS2RC2_Value *idris2rc2_negate_Integer(IDRIS2RC2_Value *x) {
  if (idris2rc2_is_unboxed(x))
    return idris2rc2_mkIntegerI64(-idris2rc2_imm_signed(x));
  return idris2rc2_integerNegateSlow(x);
}

// The shift count is read as its magnitude, as mpz_get_ui does.
static inline IDRIS2RC2_Value *idris2rc2_shiftl_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) {
  if (idris2rc2_integer_both_imm(x, y)) {
    int64_t a = idris2rc2_imm_signed(x);
    int64_t c = idris2rc2_imm_signed(y);
    if (c < 0) c = -c;
    if (c < 62) {
      int64_t r = (int64_t)((uint64_t)a << c);
      if ((r >> c) == a)
        return idris2rc2_mkIntegerI64(r);
    }
  }
  return idris2rc2_integerShiftSlow(x, y, 1);
}
static inline IDRIS2RC2_Value *idris2rc2_shiftr_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) {
  if (idris2rc2_integer_both_imm(x, y)) {
    int64_t c = idris2rc2_imm_signed(y);
    if (c < 0) c = -c;
    return IDRIS2RC2_IMM_INT64(idris2rc2_imm_signed(x) >> (c > 63 ? 63 : c));
  }
  return idris2rc2_integerShiftSlow(x, y, 0);
}

// Order of two immediates is the order of their words.
static inline int idris2rc2_integerCmp(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) {
  if (idris2rc2_integer_both_imm(x, y))
    return ((intptr_t)x > (intptr_t)y) - ((intptr_t)x < (intptr_t)y);
  return idris2rc2_integerCmpSlow(x, y);
}
static inline IDRIS2RC2_Value *idris2rc2_lt_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) { return idris2rc2_mkBool(idris2rc2_integerCmp(x, y) < 0); }
static inline IDRIS2RC2_Value *idris2rc2_gt_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) { return idris2rc2_mkBool(idris2rc2_integerCmp(x, y) > 0); }
static inline IDRIS2RC2_Value *idris2rc2_lte_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) { return idris2rc2_mkBool(idris2rc2_integerCmp(x, y) <= 0); }
static inline IDRIS2RC2_Value *idris2rc2_gte_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) { return idris2rc2_mkBool(idris2rc2_integerCmp(x, y) >= 0); }
// An immediate never equals a boxed Integer.
static inline IDRIS2RC2_Value *idris2rc2_eq_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) {
  if (idris2rc2_is_unboxed(x) || idris2rc2_is_unboxed(y))
    return idris2rc2_mkBool(x == y);
  return idris2rc2_mkBool(idris2rc2_integerCmpSlow(x, y) == 0);
}

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

// A source of at most 32 bits always fits an immediate Integer.
#define IDRIS2RC2_CAST_SMALL_TO_INTEGER(FROM, FGET)                                \
  static inline IDRIS2RC2_Value *idris2rc2_cast_##FROM##_to_Integer(IDRIS2RC2_Value *x) { \
    return IDRIS2RC2_IMM_INT64(FGET(x));                                           \
  }
IDRIS2RC2_CAST_SMALL_TO_INTEGER(Int8, idris2rc2_to_i8)
IDRIS2RC2_CAST_SMALL_TO_INTEGER(Int16, idris2rc2_to_i16)
IDRIS2RC2_CAST_SMALL_TO_INTEGER(Int32, idris2rc2_to_i32)
IDRIS2RC2_CAST_SMALL_TO_INTEGER(Bits8, idris2rc2_to_u8)
IDRIS2RC2_CAST_SMALL_TO_INTEGER(Bits16, idris2rc2_to_u16)
IDRIS2RC2_CAST_SMALL_TO_INTEGER(Bits32, idris2rc2_to_u32)
static inline IDRIS2RC2_Value *idris2rc2_cast_Int64_to_Integer(IDRIS2RC2_Value *x) { return idris2rc2_mkIntegerI64(idris2rc2_to_i64(x)); }
static inline IDRIS2RC2_Value *idris2rc2_cast_Bits64_to_Integer(IDRIS2RC2_Value *x) { return idris2rc2_mkIntegerU64(idris2rc2_to_u64(x)); }

// Char is a full Unicode scalar value (0..0x10FFFF, surrogate range
// 0xD800..0xDFFF excluded), not a C `char` -- an out-of-range source
// value (negative, or past 0x10FFFF, or landing in the surrogate hole)
// has no valid codepoint to become, so it maps to NUL rather than
// silently reinterpreting whichever low bits happened to fit. Mirrors
// Idris2's own Chez backend runtime (`cast-int-char` in support/chez/
// support.ss), the spec-correct reference this was checked against.
static inline uint32_t idris2rc2_charFromCodepoint(int64_t v) {
  if ((v >= 0 && v <= 0xD7FF) || (v >= 0xE000 && v <= 0x10FFFF)) return (uint32_t)v;
  return 0;
}

#define IDRIS2RC2_CAST_TO_CHAR(FROM, FCTY, FGET, FMK)                              \
  static inline IDRIS2RC2_Value *idris2rc2_cast_##FROM##_to_Char(IDRIS2RC2_Value *x) {         \
    return idris2rc2_mkChar(idris2rc2_charFromCodepoint((int64_t)FGET(x)));       \
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
// mpz_set_d also truncates toward zero; NaN and the infinities take it.
static inline IDRIS2RC2_Value *idris2rc2_cast_Double_to_Integer(IDRIS2RC2_Value *x) {
  double d = idris2rc2_to_double(x);
  if (d > -0x1p62 && d < 0x1p62)
    return IDRIS2RC2_IMM_INT64((int64_t)d);
  IDRIS2RC2_Integer *r = idris2rc2_mkInteger();
  mpz_set_d(r->v, d);
  return idris2rc2_integerNormalize(r);
}
static inline IDRIS2RC2_Value *idris2rc2_cast_Double_to_Char(IDRIS2RC2_Value *x) { return idris2rc2_mkChar(idris2rc2_charFromCodepoint((int64_t)idris2rc2_to_double(x))); }
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
static inline IDRIS2RC2_Value *idris2rc2_cast_Char_to_Integer(IDRIS2RC2_Value *x) { return IDRIS2RC2_IMM_INT64(idris2rc2_to_char(x)); }
// idris2rc2_cast_Char_to_string stays in numeric.c (multi-statement UTF-8
// encoding).
IDRIS2RC2_Value *idris2rc2_cast_Char_to_string(IDRIS2RC2_Value *);

// ---- Integer ----
// idris2rc2_cast_Integer_to_<Int8/16/32/64/Bits8/16/32/64/Char> and their
// shared idris2rc2_integerLsb helper, plus idris2rc2_cast_Integer_to_string,
// stay in numeric.c: integerLsb is itself multi-statement, and a `static`
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
static inline IDRIS2RC2_Value *idris2rc2_cast_Integer_to_Double(IDRIS2RC2_Value *x) {
  if (idris2rc2_is_unboxed(x))
    return idris2rc2_mkDouble((double)idris2rc2_imm_signed(x));
  return idris2rc2_mkDouble(idris2rc2_integerToDoubleSlow(x));
}
IDRIS2RC2_Value *idris2rc2_cast_Integer_to_string(IDRIS2RC2_Value *);

// ---- string ----
// idris2rc2_cast_string_to_<Char/Integer/Double> stay in numeric.c
// (multi-statement UTF-8 decode / GMP parse); the integer ones are
// one-liners around atoi/atoll, except Bits64: strtoull, since atoll stops
// at INT64_MAX. Double is NOT atof: it uses a
// locale-independent, correctly-rounded GMP parser matching the
// frontend's literal syntax (see numeric.c).
//
// The two raw (non-Value-boxed) helpers behind the Double<->string casts
// are exposed here (not just used internally by numeric.c) so that
// libs/rc2base's Data.Double.Convert can call them directly as the
// exact fallback its Eisel-Lemire/Grisu2 fast paths defer to on any
// input their own table-driven approximations can't resolve
// unambiguously -- same "%foreign straight onto a real rc2 runtime
// symbol, resolved at final link time" shape Data.Integer.GMP already
// uses for real `mpz_*` symbols.
double idris2rc2_parse_double(const char *p);
void idris2rc2_shortest_double(double v, char *buf);
static inline IDRIS2RC2_Value *idris2rc2_cast_string_to_Int8(IDRIS2RC2_Value *x) { return idris2rc2_mkInt8((int8_t)atoi(((IDRIS2RC2_String *)x)->str)); }
static inline IDRIS2RC2_Value *idris2rc2_cast_string_to_Int16(IDRIS2RC2_Value *x) { return idris2rc2_mkInt16((int16_t)atoi(((IDRIS2RC2_String *)x)->str)); }
static inline IDRIS2RC2_Value *idris2rc2_cast_string_to_Int32(IDRIS2RC2_Value *x) { return idris2rc2_mkInt32((int32_t)atoi(((IDRIS2RC2_String *)x)->str)); }
static inline IDRIS2RC2_Value *idris2rc2_cast_string_to_Int64(IDRIS2RC2_Value *x) { return idris2rc2_mkInt64((int64_t)atoll(((IDRIS2RC2_String *)x)->str)); }
static inline IDRIS2RC2_Value *idris2rc2_cast_string_to_Bits8(IDRIS2RC2_Value *x) { return idris2rc2_mkBits8((uint8_t)atoi(((IDRIS2RC2_String *)x)->str)); }
static inline IDRIS2RC2_Value *idris2rc2_cast_string_to_Bits16(IDRIS2RC2_Value *x) { return idris2rc2_mkBits16((uint16_t)atoi(((IDRIS2RC2_String *)x)->str)); }
static inline IDRIS2RC2_Value *idris2rc2_cast_string_to_Bits32(IDRIS2RC2_Value *x) { return idris2rc2_mkBits32((uint32_t)atoi(((IDRIS2RC2_String *)x)->str)); }
static inline IDRIS2RC2_Value *idris2rc2_cast_string_to_Bits64(IDRIS2RC2_Value *x) { return idris2rc2_mkBits64((uint64_t)strtoull(((IDRIS2RC2_String *)x)->str, NULL, 10)); }
IDRIS2RC2_Value *idris2rc2_cast_string_to_Double(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_string_to_Integer(IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_cast_string_to_Char(IDRIS2RC2_Value *); // first UTF-8 codepoint, or NUL for ""
