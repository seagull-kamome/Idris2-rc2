#include "numeric.h"
#include "utf8.h"

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Everything that was a one-line wrapper (unbox, apply a C operator or a
// single library call, box the result) now lives as `static inline` in
// numeric.h instead, so the C compiler can inline it at each call site
// rather than always paying for a real function call. Only the genuinely
// multi-statement functions below -- a real algorithm (Euclidean division
// for Integer), a shared non-trivial helper (`idris2rc2_mpz_lsb`) plus its
// dependent callers (can't move just the callers: the helper is `static`,
// so a copy would be needed in every translation unit that inlines a
// caller, and it isn't a one-liner itself), or measure-then-format string
// conversions -- stay defined here.

// ---- Integer (arbitrary precision, via GMP) ----
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

// ---- casts to fixed-width string ----
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
IDRIS2RC2_Value *idris2rc2_cast_Double_to_string(IDRIS2RC2_Value *x) {
  double v = idris2rc2_to_double(x);
  int l = snprintf(NULL, 0, "%f", v);
  IDRIS2RC2_String *r = idris2rc2_mkEmptyString((size_t)l + 1);
  sprintf(r->str, "%f", v);
  return (IDRIS2RC2_Value *)r;
}

// ---- Char ----
IDRIS2RC2_Value *idris2rc2_cast_Char_to_string(IDRIS2RC2_Value *x) {
  uint32_t c = idris2rc2_to_char(x);
  char buf[4];
  int n = idris2rc2_utf8EncodeInto(c, buf);
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
IDRIS2RC2_Value *idris2rc2_cast_Integer_to_Char(IDRIS2RC2_Value *x) {
  IDRIS2RC2_Integer *i = (IDRIS2RC2_Integer *)x;
  // mpz_lsb below would silently reinterpret a magnitude past 0x10FFFF
  // (or negative) into some unrelated low-32-bit codepoint; compare
  // against GMP's own arbitrary-precision value directly instead of
  // narrowing first, so a huge Integer is correctly rejected rather
  // than aliasing whatever bits happened to survive truncation.
  if ((mpz_cmp_si(i->v, 0) >= 0 && mpz_cmp_ui(i->v, 0xD7FF) <= 0) ||
      (mpz_cmp_ui(i->v, 0xE000) >= 0 && mpz_cmp_ui(i->v, 0x10FFFF) <= 0))
    return idris2rc2_mkChar((uint32_t)mpz_get_ui(i->v));
  return idris2rc2_mkChar(0);
}
IDRIS2RC2_Value *idris2rc2_cast_Integer_to_string(IDRIS2RC2_Value *x) {
  IDRIS2RC2_String *r = IDRIS2RC2_NEW(IDRIS2RC2_String);
  r->header.tag = IDRIS2RC2_TAG_STRING;
  r->str = mpz_get_str(NULL, 10, ((IDRIS2RC2_Integer *)x)->v);
  return (IDRIS2RC2_Value *)r;
}

// ---- string ----
IDRIS2RC2_Value *idris2rc2_cast_string_to_Integer(IDRIS2RC2_Value *x) {
  IDRIS2RC2_Integer *r = idris2rc2_mkInteger();
  mpz_set_str(r->v, ((IDRIS2RC2_String *)x)->str, 10);
  return (IDRIS2RC2_Value *)r;
}
IDRIS2RC2_Value *idris2rc2_cast_string_to_Char(IDRIS2RC2_Value *x) {
  char const *s = ((IDRIS2RC2_String *)x)->str;
  size_t byteLen = strlen(s);
  if (byteLen == 0)
    return idris2rc2_mkChar(0);
  size_t consumed;
  return idris2rc2_mkChar(idris2rc2_utf8DecodeAt(s, byteLen, 0, &consumed));
}
