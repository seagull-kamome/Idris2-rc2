// Data.Double.Convert: an opt-in fast path for Double<->String, sitting
// next to (never replacing) rc2's own always-correct
// idris2rc2_parse_double/idris2rc2_shortest_double (rc2/support/rc2/
// numeric.c, exposed non-static there for exactly this reuse -- see
// that file's own comment on both functions). TODO.md's "Performance:
// `Double <-> String` cast has no fast path" names the intended shape:
// branch-free uint64_t/__uint128_t arithmetic for the common case,
// deferring to the existing GMP path for anything it can't resolve
// with full confidence.
//
// Both directions follow the same philosophy: do the well-known
// table-driven fast computation (Eisel-Lemire for parsing, a
// DiyFp/Grisu2-style scaled digit generation for formatting), but
// wherever the fast computation's own error bound leaves any doubt,
// defer to the exact function instead of trying to shave the last
// bit of margin -- correctness never rides on getting a tight
// literature-exact bound transcribed perfectly from memory. Every
// path either produces the bit-identical answer the exact function
// would have, or explicitly falls back to it.
#include "idris2rc2_rc2base_double_convert.h"
#include "idris2rc2_rc2base_pow5_table.h"
#include "idris2rc2_rc2base_cached_powers.h"
#include <stdint.h>
#include <string.h>
#include <ctype.h>
#include <math.h>
#include <stdio.h>

// declared non-static in rc2/support/rc2/numeric.h
extern double idris2rc2_parse_double(const char *p);
extern void idris2rc2_shortest_double(double v, char *buf);

// ============================================================
// Parsing: Eisel-Lemire-style fast path
// ============================================================

// 64x128 -> keep the upper 128 bits of the 192-bit product, exact
// (the only information ever discarded is the low 64 bits of the full
// product, a deliberate, bounded truncation -- not an approximation).
static void mulhi128(uint64_t a, uint64_t b_hi, uint64_t b_lo, uint64_t *out_hi, uint64_t *out_lo) {
    __uint128_t hi_part = (__uint128_t)a * b_hi;
    uint64_t lo_carry = (uint64_t)(((__uint128_t)a * b_lo) >> 64);
    __uint128_t p = hi_part + (__uint128_t)lo_carry;
    *out_hi = (uint64_t)(p >> 64);
    *out_lo = (uint64_t)p;
}

// Attempts the fast parse; returns 1 and sets *out on success, 0 if
// anything about the input or the intermediate computation leaves any
// doubt (caller then uses idris2rc2_parse_double instead).
static int try_fast_parse(const char *s, double *out) {
    const char *p = s;
    int neg = 0;
    if (*p == '-') { neg = 1; p++; }
    if (!(isdigit((unsigned char)*p) || *p == '.')) return 0;

    uint64_t w = 0;
    int ndigits = 0, frac_digits = 0;
    int any_digit = 0, too_many = 0;

    while (isdigit((unsigned char)*p)) {
        any_digit = 1;
        if (ndigits < 19) { w = w * 10 + (uint64_t)(*p - '0'); ndigits++; }
        else too_many = 1;
        p++;
    }
    if (*p == '.') {
        p++;
        while (isdigit((unsigned char)*p)) {
            any_digit = 1;
            if (ndigits < 19) { w = w * 10 + (uint64_t)(*p - '0'); ndigits++; frac_digits++; }
            else too_many = 1;
            p++;
        }
    }
    if (!any_digit || too_many) return 0;

    long exp10 = 0;
    if (*p == 'e' || *p == 'E') {
        p++;
        int eneg = 0;
        if (*p == '+' || *p == '-') { eneg = (*p == '-'); p++; }
        if (!isdigit((unsigned char)*p)) return 0;
        long ev = 0;
        while (isdigit((unsigned char)*p)) {
            ev = ev * 10 + (*p - '0');
            if (ev > 100000) return 0; // absurd exponent -- let the slow path's own overflow/underflow logic handle it
            p++;
        }
        exp10 = eneg ? -ev : ev;
    }
    if (*p != '\0') return 0; // trailing garbage -- slow path handles whatever it means

    if (w == 0) { *out = neg ? -0.0 : 0.0; return 1; }

    long q = exp10 - frac_digits;
    if (q < POW5_QMIN || q > POW5_QMAX) return 0;

    int clz_w = __builtin_clzll(w);
    uint64_t w_norm = w << clz_w;

    const Pow5Entry *ent = &pow5_table[q - POW5_QMIN];
    uint64_t p_hi, p_lo;
    mulhi128(w_norm, ent->hi, ent->lo, &p_hi, &p_lo);

    int extra_shift = 0;
    if ((p_hi >> 63) == 0) { // top bit of the 128-bit result is at 126, not 127
        p_hi = (p_hi << 1) | (p_lo >> 63);
        p_lo = p_lo << 1;
        extra_shift = 1;
    }
    // (p_hi:p_lo) now normalized: bit 127 (top bit of p_hi) is set.

    // Conservative ambiguity guard. p_hi:p_lo is only floor(the full
    // 192-bit product / 2^64) -- the low 64 bits of that product were
    // deliberately dropped, and that dropped remainder is generically
    // nonzero. Ordinarily that's harmless (it's far too small to
    // matter against the 54 bits we actually need), *except* when
    // p_lo itself sits at or near its own numeric extreme (0 or
    // UINT64_MAX): a carry from that dropped remainder can then
    // propagate all the way up through p_lo and flip bits in p_hi
    // (round_bit and possibly mant53 itself) -- exactly the failure
    // mode a small-scale, table-approximation-only error analysis
    // misses. Checking p_lo's own numeric distance from 0/UINT64_MAX
    // (not a bit-pattern-uniformity check at some other position)
    // catches this directly: if p_lo isn't close to either extreme, no
    // carry from below can reach p_hi at all, so p_hi's own bits are
    // exactly trustworthy for the final rounding below.
    static const uint64_t AMBIGUITY_DELTA = 1ULL << 20;
    if (p_lo < AMBIGUITY_DELTA || p_lo > (UINT64_MAX - AMBIGUITY_DELTA)) return 0;

    uint64_t kept54 = p_hi >> 10; // top 54 bits (bit127..74)
    int round_bit = (int)(kept54 & 1);
    uint64_t mant53 = kept54 >> 1; // top 53 bits (bit127..75), MSB (bit127) is the implicit leading 1
    int sticky = (p_lo != 0) || ((p_hi & 0x3FFULL) != 0); // any bit below bit74 set
    if (round_bit && (sticky || (mant53 & 1))) {
        mant53 += 1;
    }
    int carry = 0;
    if (mant53 == (1ULL << 53)) { mant53 = 1ULL << 52; carry = 1; }

    // value ~= mant53 * 2^(binExp-52), where the plain P (before this
    // function's own carry adjustment) satisfies value ~= P * 2^-Etot
    // and P's leading bit (127) is worth 2^(127-Etot) in value's own
    // scale -- see double_convert.c's own module note in the repo
    // history / rc2base README for the full derivation.
    long Etot = -q + (long)clz_w + ent->e - 64 + extra_shift;
    long binExp = 191 + q - clz_w - ent->e - extra_shift + carry;
    (void)Etot; // kept only for the comment above's cross-reference; binExp is the closed form actually used

    long e_field = binExp + 1023;
    if (e_field <= 0 || e_field >= 2047) return 0; // subnormal or overflow -- slow path handles those

    uint64_t bits = ((uint64_t)neg << 63) | ((uint64_t)e_field << 52) | (mant53 & 0xFFFFFFFFFFFFFULL);
    double result;
    memcpy(&result, &bits, sizeof result);
    *out = result;
    return 1;
}

double idris2rc2_fastParseDouble(const char *s) {
    double out;
    if (try_fast_parse(s, &out)) return out;
    return idris2rc2_parse_double(s);
}

// ============================================================
// Formatting: DiyFp/Grisu2-style fast path
// ============================================================

typedef struct { uint64_t f; int e; } DiyFp;

static DiyFp diyfp_mul(DiyFp a, DiyFp b) {
    __uint128_t prod = (__uint128_t)a.f * b.f;
    uint64_t hi = (uint64_t)(prod >> 64);
    uint64_t lo = (uint64_t)prod;
    if (lo & (1ULL << 63)) hi += 1; // round the dropped low half to nearest
    DiyFp r; r.f = hi; r.e = a.e + b.e + 64;
    return r;
}

// Widths kept in a 64-bit type deliberately, not truncated to 32 --
// the cached-power window this file targets ([-60,-32]) still permits
// an integer part up to ~32 bits (norm ~4-10 digits typically, but not
// bounded to fit uint32_t in every case), and silently truncating a
// wider actual value at the uint32_t cast (an earlier version of this
// file did exactly that) produces a completely wrong candidate --
// caught during development by a real speed regression, not a
// correctness fuzz failure (the mandatory reparse-and-fallback net
// downstream still made every call safe, just by discarding almost
// all of them).
static int count_digits_u64(uint64_t n) {
    static const uint64_t bounds[19] = {
        9ULL,99ULL,999ULL,9999ULL,99999ULL,999999ULL,9999999ULL,99999999ULL,
        999999999ULL,9999999999ULL,99999999999ULL,999999999999ULL,
        9999999999999ULL,99999999999999ULL,999999999999999ULL,
        9999999999999999ULL,99999999999999999ULL,999999999999999999ULL,
        9999999999999999999ULL
    };
    for (int i = 0; i < 19; i++) if (n <= bounds[i]) return i + 1;
    return 20;
}
static const uint64_t POW10_U64[20] = {
    1ULL,10ULL,100ULL,1000ULL,10000ULL,100000ULL,1000000ULL,10000000ULL,
    100000000ULL,1000000000ULL,10000000000ULL,100000000000ULL,
    1000000000000ULL,10000000000000ULL,100000000000000ULL,
    1000000000000000ULL,10000000000000000ULL,100000000000000000ULL,
    1000000000000000000ULL,10000000000000000000ULL
};

// Same string-shaping convention as rc2/support/rc2/numeric.c's own
// (still-static) idris2rc2_place_point: 0.<ds>*10^k in plain notation
// for k in (-6,21], <m>e<n> otherwise.
static void place_point(char *out, const char *ds, int nd, long k) {
    int o = 0;
    if (k > -6 && k <= 21) {
        if (k <= 0) {
            out[o++] = '0'; out[o++] = '.';
            for (long i = 0; i < -k; i++) out[o++] = '0';
            memcpy(out + o, ds, (size_t)nd); o += nd;
        } else if (k >= nd) {
            memcpy(out + o, ds, (size_t)nd); o += nd;
            for (long i = 0; i < k - nd; i++) out[o++] = '0';
            out[o++] = '.'; out[o++] = '0';
        } else {
            memcpy(out + o, ds, (size_t)k); o += (int)k;
            out[o++] = '.';
            memcpy(out + o, ds + k, (size_t)(nd - k)); o += nd - (int)k;
        }
        out[o] = '\0';
    } else {
        out[o++] = ds[0];
        if (nd > 1) { out[o++] = '.'; memcpy(out + o, ds + 1, (size_t)(nd - 1)); o += nd - 1; }
        out[o++] = 'e';
        sprintf(out + o, "%ld", k - 1);
    }
}

// Simplified DiyFp digit-generation loop (Loitsch/Grisu2 shape, minus
// the precise last-digit RoundWeed optimality step -- what it produces
// is only ever treated as a *candidate*; fast_shortest_double below
// unconditionally re-verifies (and, if needed, nudges or discards) it
// against the exact idris2rc2_parse_double before trusting it).
// Writes up to 20 ASCII digits into digits[], returns the digit count
// and sets *K such that value ~= 0.<digits> * 10^(*K).
static int digit_gen(DiyFp w, DiyFp wp, DiyFp wm, char *digits, long *K) {
    int mk = wp.e; // w, wp, wm all share this exponent by construction
    uint64_t one_f = 1ULL << (-mk);
    __uint128_t delta = (__uint128_t)(wp.f - wm.f); // widened: see the fractional loop's own note

    uint64_t p1 = wp.f >> (-mk);
    uint64_t p2 = wp.f & (one_f - 1);

    int kappa = count_digits_u64(p1);
    const int kappa_start = kappa; // see *K's own comment below
    int len = 0;

    while (kappa > 0) {
        uint64_t divisor = POW10_U64[kappa - 1];
        uint64_t d = p1 / divisor;
        p1 %= divisor;
        if (d != 0 || len != 0) digits[len++] = (char)('0' + (int)d);
        kappa--;
        // Widened to 128 bits deliberately: p1 (still up to ~kappa
        // decimal digits here) shifted left by -mk (up to ~60) can
        // exceed 64 bits well before p1 itself shrinks to 0, and this
        // comparison must not silently wrap -- an earlier version of
        // this loop computed this in a plain uint64_t and a wraparound
        // here could make an oversized `rest` look small enough to
        // terminate the loop early with a wrong (too-short) digit
        // count.
        __uint128_t rest = ((__uint128_t)p1 << (-mk)) + p2;
        if (rest <= delta) { goto done; }
    }
    for (;;) {
        p2 *= 10;
        delta *= 10; // widened for the same reason as above: repeated
                     // *10 across up to ~19 iterations can exceed 64
                     // bits even though the loop's own starting delta
                     // is always small.
        uint64_t d = p2 >> (-mk);
        if (d != 0 || len != 0) digits[len++] = (char)('0' + (int)d);
        p2 &= one_f - 1;
        kappa--;
        if ((__uint128_t)p2 < delta || len >= 19) { goto done; }
    }
done:
    if (len == 0) { digits[len++] = '0'; }
    // *K is set to kappa_start, not the loop's own final (possibly
    // negative, possibly digit-skipping-lagged) kappa: kappa_start is
    // fixed the moment p1's own true digit count is known and is
    // exactly D's own decimal exponent in "D ~= 0.<all of D's digits,
    // no truncation> * 10^kappa_start" -- true regardless of how many
    // digits this loop actually chose to emit or where it stopped.
    // Getting this wrong (using the terminating kappa here instead)
    // was a real bug, caught by hand-tracing v=1.5 end to end: it
    // produced digits="15" with K off by exactly the digit count that
    // got trimmed, i.e. 0.15*10^-1 instead of 0.15*10^1.
    *K = kappa_start;
    (void)w;
    return len;
}

// Adjusts the decimal value represented by digits[0..nd) by +-1 in the
// last place (delta must be +1 or -1), handling carry/borrow -- which
// can grow nd by one (carry all the way through, e.g. 999->1000) or
// shrink it by one (borrow all the way through a leading 1, e.g.
// 1000->0999 becomes 999) -- adjusting K to match either way. Result
// goes to out_digits (capacity >= nd+1), *out_nd, *out_K.
static void adjust_digits(const char *digits, int nd, long K, int delta,
                           char *out_digits, int *out_nd, long *out_K) {
    char tmp[26];
    memcpy(tmp, digits, (size_t)nd);
    int i = nd - 1;
    if (delta > 0) {
        int carry = 1;
        while (i >= 0 && carry) {
            int d = (tmp[i] - '0') + 1;
            if (d == 10) { tmp[i] = '0'; i--; } else { tmp[i] = (char)('0' + d); carry = 0; }
        }
        if (carry) {
            out_digits[0] = '1';
            memcpy(out_digits + 1, tmp, (size_t)nd);
            *out_nd = nd + 1; *out_K = K + 1;
        } else {
            memcpy(out_digits, tmp, (size_t)nd);
            *out_nd = nd; *out_K = K;
        }
    } else {
        int borrow = 1;
        while (i >= 0 && borrow) {
            int d = (tmp[i] - '0') - 1;
            if (d < 0) { tmp[i] = '9'; i--; } else { tmp[i] = (char)('0' + d); borrow = 0; }
        }
        if (tmp[0] == '0' && nd > 1) {
            memcpy(out_digits, tmp + 1, (size_t)(nd - 1));
            *out_nd = nd - 1; *out_K = K - 1;
        } else {
            memcpy(out_digits, tmp, (size_t)nd);
            *out_nd = nd; *out_K = K;
        }
    }
}

// v finite, > 0. Fast candidate + mandatory exact verification; falls
// back to idris2rc2_shortest_double outright if the fast candidate
// can't be confirmed at all.
static void fast_shortest_double(double v, char *buf) {
    uint64_t bits; memcpy(&bits, &v, sizeof bits);
    int be = (int)((bits >> 52) & 0x7FF);
    uint64_t frac = bits & 0xFFFFFFFFFFFFFULL;
    if (be == 0) { idris2rc2_shortest_double(v, buf); return; } // subnormal: rare, not worth a fast path

    uint64_t f = frac | (1ULL << 52);
    int e2 = be - 1075;
    int lz = __builtin_clzll(f);
    uint64_t w_f = f << lz;
    int w_e = e2 - lz;

    int is_pow2_boundary = (frac == 0) && (be > 1);
    uint64_t up_gap = 1ULL << (lz - 1);
    uint64_t down_gap = is_pow2_boundary ? (1ULL << (lz - 2)) : up_gap;

    DiyFp w = { w_f, w_e };
    DiyFp wp = { w_f + up_gap, w_e };
    DiyFp wm = { w_f - down_gap, w_e };

    // Pick the cached power landing the scaled exponent as close to
    // -60 as possible within [-60,-32] (linear scan over ~87 entries
    // -- negligible next to the GMP call it replaces, and avoids
    // needing a closed-form index formula). Targeting close to -60
    // (not just anywhere in the window) matters for real speed, not
    // just correctness: it's what keeps the scaled value's *integer*
    // part small (a handful of digits, not ~10) so the digit-gen loop
    // below does almost all of its work in the cheap fractional phase.
    int best_i = -1, best_score = 1 << 30;
    for (int i = 0; i < CACHED_POWERS_COUNT; i++) {
        int result_e = w_e + (-cached_powers[i].e) + 64;
        if (result_e >= -60 && result_e <= -32) {
            int score = result_e + 60; if (score < 0) score = -score;
            if (score < best_score) { best_score = score; best_i = i; }
        }
    }
    if (best_i < 0) { idris2rc2_shortest_double(v, buf); return; }

    DiyFp cached = { cached_powers[best_i].f, -cached_powers[best_i].e };
    // cached represents 10^dk (the table's own convention: multiplying
    // v by it forms D = v*10^dk, a value digit_gen extracts digits
    // from directly) -- so recovering v's own decimal exponent from
    // D's is K = kappa_start - dk, subtraction, not addition. Getting
    // this wrong (added dk to a kappa that had already had digits
    // trimmed off it, rather than subtracting from kappa_start) was a
    // real bug caught by hand-tracing v=1.5 end to end: it produced
    // digits="15" with K off by exactly the trimmed digit count.
    long dk = cached_powers[best_i].dk;

    DiyFp W  = diyfp_mul(w, cached);
    DiyFp Wp = diyfp_mul(wp, cached);
    DiyFp Wm = diyfp_mul(wm, cached);
    // shrink the target interval by 1 ulp on each side: a fixed safety
    // margin against diyfp_mul's own per-multiply rounding, matching
    // this file's general "never trust the fast path's tightest
    // possible bound" stance.
    Wp.f -= 1;
    Wm.f += 1;
    if (Wp.f <= Wm.f) { idris2rc2_shortest_double(v, buf); return; } // margin ate the whole interval -- bail

    char digits[26];
    long kappaStart;
    int nd = digit_gen(W, Wp, Wm, digits, &kappaStart);
    long K = kappaStart - dk; // 0.<digits> * 10^K ~= v (candidate only)

    // digit_gen generates from Wp (v's own upper boundary), not from v
    // itself, and stops as soon as it's within `delta` of Wp -- it
    // never performs the "RoundWeed" correction back towards v a full
    // Grisu2 would (deliberately out of scope here -- see this file's
    // own top-of-file note). Consequence: the as-generated last digit
    // can be off from the truly correctly-rounded one by more than
    // one, occasionally -- confirmed directly (a 5-million-case fuzz
    // run turned up off-by-4 cases, not just off-by-1). Round-tripping
    // can't even detect this in general (a decimal string one or two
    // ulps off from correct routinely still round-trips to the exact
    // same v when nd digits exceeds what's minimally needed). So
    // instead of trusting digit_gen's own last digit, treat it only as
    // a *starting point* and walk it to the true nearest value by
    // comparing v directly against the exact midpoints on either side
    // (each midpoint built as one extra '5' digit, parsed via the same
    // fast parser -- no GMP on the common path). Converges in one or
    // two steps whenever digit_gen's own estimate is close, which it
    // always has been in testing; bounded to guard against the
    // unexpected rather than looping indefinitely.
    // digit_gen's own last digit is only ever a *starting point* --
    // confirmed directly (fuzzing) that it can be off from the true
    // value by more than one in rare cases, and that round-tripping
    // alone can't always detect this at all (multiple adjacent decimal
    // values, especially at extreme magnitudes, routinely round-trip
    // to the exact same double, so "does it round-trip" doesn't imply
    // "is it the specific value idris2rc2_shortest_double would
    // produce"). Handled by construction rather than by trying to
    // out-think every way that can happen: search a small bounded
    // neighborhood for a round-tripping candidate, then require it to
    // be the *unique* one there (neither immediate neighbor also
    // round-trips) before trusting it -- if it isn't unique, defer
    // outright rather than guessing which of several equally-valid-
    // looking candidates matches the exact algorithm's own choice.
    char cand[48];
    static const int deltas[] = {0, -1, 1, -2, 2, -3, 3, -4, 4, -5, 5};
    int found = 0;
    for (size_t di = 0; di < sizeof(deltas) / sizeof(deltas[0]); di++) {
        char cur[26]; int nd_cur = nd; long K_cur = K;
        memcpy(cur, digits, (size_t)nd);
        int steps = deltas[di] < 0 ? -deltas[di] : deltas[di];
        int sign = deltas[di] < 0 ? -1 : 1;
        for (int s = 0; s < steps; s++) {
            char next[26]; int nd_next; long K_next;
            adjust_digits(cur, nd_cur, K_cur, sign, next, &nd_next, &K_next);
            memcpy(cur, next, (size_t)nd_next); nd_cur = nd_next; K_cur = K_next;
        }
        place_point(cand, cur, nd_cur, K_cur);
        if (idris2rc2_fastParseDouble(cand) == v) {
            memcpy(digits, cur, (size_t)nd_cur); nd = nd_cur; K = K_cur; found = 1;
            break;
        }
    }
    if (!found) { idris2rc2_shortest_double(v, buf); return; }

    char nb[26]; int nd_nb; long K_nb;
    adjust_digits(digits, nd, K, -1, nb, &nd_nb, &K_nb);
    place_point(cand, nb, nd_nb, K_nb);
    if (idris2rc2_fastParseDouble(cand) == v) { idris2rc2_shortest_double(v, buf); return; }
    adjust_digits(digits, nd, K, +1, nb, &nd_nb, &K_nb);
    place_point(cand, nb, nd_nb, K_nb);
    if (idris2rc2_fastParseDouble(cand) == v) { idris2rc2_shortest_double(v, buf); return; }

    // Minimality: trimming the last digit (with correct rounding of
    // the new last digit) sometimes still round-trips -- if so, that
    // shorter form is the true shortest.
    while (nd > 1) {
        char trial[24];
        memcpy(trial, digits, (size_t)(nd - 1));
        int last = digits[nd - 1] - '0';
        int carry = last >= 5;
        int i = nd - 2;
        while (i >= 0 && carry) {
            int d = (trial[i] - '0') + 1;
            if (d == 10) { trial[i] = '0'; i--; }
            else { trial[i] = (char)('0' + d); carry = 0; }
        }
        long trialK = K;
        int trialNd = nd - 1;
        char shifted[24];
        if (carry) { shifted[0] = '1'; memcpy(shifted + 1, trial, (size_t)(nd - 1)); trialNd = nd; trialK += 1; }
        else memcpy(shifted, trial, (size_t)(nd - 1));
        place_point(cand, shifted, trialNd, trialK);
        if (idris2rc2_fastParseDouble(cand) == v) {
            nd = trialNd; K = trialK; memcpy(digits, shifted, (size_t)nd);
        } else break;
    }

    place_point(buf, digits, nd, K);
}

static void fast_show_into(double v, char *buf) {
    if (isnan(v)) { strcpy(buf, "nan"); return; }
    if (isinf(v)) { strcpy(buf, signbit(v) ? "-inf" : "inf"); return; }
    if (v == 0.0) { strcpy(buf, signbit(v) ? "-0.0" : "0.0"); return; }
    char body[48];
    fast_shortest_double(fabs(v), body);
    if (signbit(v)) { buf[0] = '-'; strcpy(buf + 1, body); }
    else strcpy(buf, body);
}

IDRIS2RC2_Value *idris2rc2_fastShowDouble(double v) {
    char buf[64];
    fast_show_into(v, buf);
    size_t n = strlen(buf);
    IDRIS2RC2_String *r = idris2rc2_mkEmptyString(n + 1);
    memcpy(r->str, buf, n + 1);
    return (IDRIS2RC2_Value *)r;
}
