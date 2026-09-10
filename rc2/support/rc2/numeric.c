#include "numeric.h"
#include "utf8.h"

#include <inttypes.h>
#include <math.h>
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

// ---- Double <-> String: locale-independent, matches the frontend ----
//
// Replaces the old snprintf("%f") / atof pair, which followed the
// process LC_NUMERIC (a "de_DE" locale would print/parse "3,14").
// `cast` is a language-level conversion bound to Idris's numeric-literal
// syntax, which is always '.'-based, so the runtime carries its own
// decimal<->binary code rather than forcing a "C" locale around libc on
// every call. See rc2/doc/runtime-lifecycle.md.
//
// No fast path yet -- every call allocates GMP temporaries. A branch-
// free path (Eisel-Lemire parse, Grisu/Ryu print) is deferred; see
// rc2/TODO.md's "Double <-> String fast path" entry. `Double -> String`
// is not on any hot path today.
//
// LP64 assumption: `unsigned long` is 64-bit, so `mpz_set_ui` / the
// `unsigned long` GMP entry points take a full `uint64_t` mantissa
// directly. This whole backend is Linux/x86-64 only (see env.sh).

// Nearest double to num/den (both strictly > 0), round to nearest,
// ties to even. May return +inf on overflow or 0.0 on underflow;
// subnormals go through ldexp (a second rounding there is possible in
// principle but not for any input this project exercises).
static double idris2rc2_ratio_to_double(mpz_t num_in, mpz_t den_in) {
  if (mpz_sgn(num_in) == 0) return 0.0;        // guard the scaling loops below
  mpz_t num, den, q, r, r2;
  mpz_inits(num, den, q, r, r2, NULL);
  mpz_set(num, num_in);
  mpz_set(den, den_in);

  long bn = (long)mpz_sizeinbase(num, 2);
  long bd = (long)mpz_sizeinbase(den, 2);
  long s = 53 - (bn - bd);            // scale num by 2^s (or den by 2^-s)
  if (s >= 0) mpz_mul_2exp(num, num, (mp_bitcnt_t)s);
  else        mpz_mul_2exp(den, den, (mp_bitcnt_t)(-s));
  mpz_fdiv_qr(q, r, num, den);

  // pin the quotient into [2^52, 2^53); the estimate above is within
  // one bit either way, so each loop runs at most once or twice.
  while (mpz_sizeinbase(q, 2) < 53) {
    mpz_mul_2exp(num, num, 1); s += 1;
    mpz_fdiv_qr(q, r, num, den);
  }
  while (mpz_sizeinbase(q, 2) > 53) {
    mpz_mul_2exp(den, den, 1); s -= 1;
    mpz_fdiv_qr(q, r, num, den);
  }

  // round: compare 2*r against den
  mpz_mul_2exp(r2, r, 1);
  int c = mpz_cmp(r2, den);
  if (c > 0 || (c == 0 && mpz_odd_p(q))) {
    mpz_add_ui(q, q, 1);
    if (mpz_sizeinbase(q, 2) > 53) { mpz_fdiv_q_2exp(q, q, 1); s -= 1; }
  }

  double mant = mpz_get_d(q);         // exact: q holds at most 53 bits
  double result = ldexp(mant, (int)(-s));
  mpz_clears(num, den, q, r, r2, NULL);
  return result;
}

// Parse a bare decimal (no sign, no leading space) starting at `p` into
// (`sig` * 10^`*dexp`). Returns the position past the number, or `p`
// unchanged if there were no mantissa digits. Accepts
//   digits [ '.' digits ] [ (e|E) [+|-] digits ]
// -- the shape Parser.Lexer.Source's `doubleLit` and
// Data.String.parseDouble both produce.
static const char *idris2rc2_scan_decimal(const char *p, mpz_t sig, long *dexp) {
  const char *start = p;
  long de = 0;
  int any = 0;
  mpz_set_ui(sig, 0);
  for (; *p >= '0' && *p <= '9'; p++) {
    mpz_mul_ui(sig, sig, 10);
    mpz_add_ui(sig, sig, (unsigned long)(*p - '0'));
    any = 1;
  }
  if (*p == '.') {
    p++;
    for (; *p >= '0' && *p <= '9'; p++) {
      mpz_mul_ui(sig, sig, 10);
      mpz_add_ui(sig, sig, (unsigned long)(*p - '0'));
      de -= 1;
      any = 1;
    }
  }
  if (!any) return start;
  if (*p == 'e' || *p == 'E') {
    const char *ep = p + 1;
    int esign = 0;
    if (*ep == '+' || *ep == '-') { esign = (*ep == '-'); ep++; }
    if (*ep >= '0' && *ep <= '9') {
      long ev = 0;
      for (; *ep >= '0' && *ep <= '9'; ep++) {
        ev = ev * 10 + (*ep - '0');
        if (ev > 1000000000L) ev = 1000000000L;   // any larger just means inf/0
      }
      de += esign ? -ev : ev;
      p = ep;
    }
    // a bare 'e' with no exponent digits stays unconsumed, like strtod
  }
  *dexp = de;
  return p;
}

// The core: C-string -> double, locale-independent, correctly rounded.
// Reused by the shortest-string formatter for its round-trip check.
static double idris2rc2_parse_double(const char *p) {
  while (*p == ' ' || (*p >= '\t' && *p <= '\r')) p++;
  int neg = 0;
  if (*p == '+' || *p == '-') { neg = (*p == '-'); p++; }

  mpz_t sig;
  mpz_init(sig);
  long dexp = 0;
  const char *end = idris2rc2_scan_decimal(p, sig, &dexp);

  double out;
  if (end == p || mpz_sgn(sig) == 0) {
    out = 0.0;                          // nothing parsed, or all-zero mantissa
  } else {
    long mag = (long)mpz_sizeinbase(sig, 10) + dexp;   // ~ log10 of the value
    if (mag > 340) {
      out = HUGE_VAL;                   // beyond DBL_MAX
    } else if (mag < -340) {
      out = 0.0;                        // below the smallest subnormal
    } else {
      mpz_t num, den, ten;
      mpz_inits(num, den, ten, NULL);
      mpz_set(num, sig);
      mpz_set_ui(den, 1);
      mpz_ui_pow_ui(ten, 10, (unsigned long)(dexp >= 0 ? dexp : -dexp));
      if (dexp >= 0) mpz_mul(num, num, ten);
      else           mpz_set(den, ten);
      out = idris2rc2_ratio_to_double(num, den);
      mpz_clears(num, den, ten, NULL);
    }
  }
  mpz_clear(sig);
  return neg ? -out : out;
}

IDRIS2RC2_Value *idris2rc2_cast_string_to_Double(IDRIS2RC2_Value *x) {
  return idris2rc2_mkDouble(idris2rc2_parse_double(((IDRIS2RC2_String *)x)->str));
}

// Place a decimal point in the significant-digit string `ds` (length
// `nd`, no leading or trailing zero) so that the value is
// 0.<ds> * 10^k, writing a C-parseable literal into `out`. Plain
// notation for k in (-6, 21], `<m>e<n>` otherwise.
static void idris2rc2_place_point(char *out, const char *ds, int nd, long k) {
  int o = 0;
  if (k > -6 && k <= 21) {
    if (k <= 0) {
      out[o++] = '0';
      out[o++] = '.';
      for (long i = 0; i < -k; i++) out[o++] = '0';
      memcpy(out + o, ds, (size_t)nd); o += nd;
    } else if (k >= nd) {
      memcpy(out + o, ds, (size_t)nd); o += nd;
      for (long i = 0; i < k - nd; i++) out[o++] = '0';
      out[o++] = '.';
      out[o++] = '0';
    } else {
      memcpy(out + o, ds, (size_t)k); o += (int)k;
      out[o++] = '.';
      memcpy(out + o, ds + k, (size_t)(nd - k)); o += nd - (int)k;
    }
    out[o] = '\0';
  } else {
    out[o++] = ds[0];
    if (nd > 1) {
      out[o++] = '.';
      memcpy(out + o, ds + 1, (size_t)(nd - 1)); o += nd - 1;
    }
    out[o++] = 'e';
    // integer conversion -- LC_NUMERIC only touches the radix char and
    // (with the unused ' flag) grouping, neither of which applies here.
    sprintf(out + o, "%ld", k - 1);
  }
}

// Shortest decimal string that round-trips to `v` (finite, > 0), into
// `buf` (<= 32 bytes needed). Probe significant-digit counts p = 1..17:
// round `v` to `p` significant decimal digits with an exact GMP
// division, form the literal, and keep the first that re-parses to
// exactly `v`. 17 significant digits always round-trip an IEEE double,
// so the loop always terminates with a match.
static void idris2rc2_shortest_double(double v, char *buf) {
  uint64_t bits;
  memcpy(&bits, &v, sizeof bits);
  int be = (int)((bits >> 52) & 0x7FF);
  uint64_t frac = bits & 0xFFFFFFFFFFFFFULL;
  uint64_t mant;
  int e2;
  if (be == 0) { mant = frac;                   e2 = -1074; }
  else         { mant = frac | (1ULL << 52);    e2 = be - 1075; }

  int e10 = (int)floor(log10(v));                // rough; off-by-one is self-correcting

  mpz_t num, den, pw, N, R, r2;
  mpz_inits(num, den, pw, N, R, r2, NULL);

  buf[0] = '\0';
  for (int p = 1; p <= 17; p++) {
    // scale v by 10^q10 so the rounded integer has ~p digits:
    long q10 = (long)p - 1 - e10;
    // v * 10^q10 = mant * 2^e2 * 10^q10
    if (q10 >= 0) {
      // = (mant * 5^q10) * 2^(e2 + q10)
      mpz_ui_pow_ui(pw, 5, (unsigned long)q10);
      mpz_mul_ui(num, pw, (unsigned long)mant);   // LP64: mant fits in a ulong
      mpz_set_ui(den, 1);
    } else {
      // = mant * 2^(e2 + q10) / 5^(-q10)
      mpz_set_ui(num, (unsigned long)mant);
      mpz_ui_pow_ui(den, 5, (unsigned long)(-q10));
    }
    long sh = (long)e2 + q10;
    if (sh >= 0) mpz_mul_2exp(num, num, (mp_bitcnt_t)sh);
    else         mpz_mul_2exp(den, den, (mp_bitcnt_t)(-sh));

    // N = round(num / den), ties to even
    mpz_fdiv_qr(N, R, num, den);
    mpz_mul_2exp(r2, R, 1);
    int c = mpz_cmp(r2, den);
    if (c > 0 || (c == 0 && mpz_odd_p(N))) mpz_add_ui(N, N, 1);
    if (mpz_sgn(N) == 0) continue;

    // N holds ~p digits (p <= 17, plus at most one from an off-by-one
    // log10 estimate), so it always fits this buffer.
    char dstr[24];
    mpz_get_str(dstr, 10, N);
    int L = (int)strlen(dstr);
    int strip = 0;
    while (L - strip > 1 && dstr[L - 1 - strip] == '0') strip++;
    int nd = L - strip;
    dstr[nd] = '\0';
    long exp10 = (long)strip - q10;               // value ~ dstr * 10^exp10
    long k = nd + exp10;                          // digits left of the B-D point

    char cand[48];
    idris2rc2_place_point(cand, dstr, nd, k);

    if (idris2rc2_parse_double(cand) == v) { strcpy(buf, cand); break; }
  }
  mpz_clears(num, den, pw, N, R, r2, NULL);
}

IDRIS2RC2_Value *idris2rc2_cast_Double_to_string(IDRIS2RC2_Value *x) {
  double v = idris2rc2_to_double(x);
  char buf[64];
  if (isnan(v)) {
    strcpy(buf, "nan");
  } else if (isinf(v)) {
    strcpy(buf, signbit(v) ? "-inf" : "inf");
  } else if (v == 0.0) {
    strcpy(buf, signbit(v) ? "-0.0" : "0.0");
  } else {
    char body[48];
    idris2rc2_shortest_double(fabs(v), body);
    if (signbit(v)) { buf[0] = '-'; strcpy(buf + 1, body); }
    else            { strcpy(buf, body); }
  }
  size_t n = strlen(buf);
  IDRIS2RC2_String *r = idris2rc2_mkEmptyString(n + 1);
  memcpy(r->str, buf, n + 1);
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
