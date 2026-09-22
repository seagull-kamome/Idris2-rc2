// Throwaway standalone fuzz harness (not part of the shipped build) --
// compares idris2rc2_fastParseDouble/idris2rc2_fastShowDouble against
// the exact idris2rc2_parse_double/idris2rc2_shortest_double for a
// large number of cases. Used only during development; not installed,
// not referenced by rc2base.ipkg or the Makefile.
#include "idris2rc2_rc2base_double_convert.h"
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include <stdlib.h>

extern double idris2rc2_parse_double(const char *p);
extern void idris2rc2_shortest_double(double v, char *buf);

static const char *fastShowStr(double v) {
    return (const char *)((IDRIS2RC2_String *)idris2rc2_fastShowDouble(v))->str;
}

static void exact_show(double v, char *buf) {
    if (isnan(v)) { strcpy(buf, "nan"); return; }
    if (isinf(v)) { strcpy(buf, signbit(v) ? "-inf" : "inf"); return; }
    if (v == 0.0) { strcpy(buf, signbit(v) ? "-0.0" : "0.0"); return; }
    char body[48];
    idris2rc2_shortest_double(fabs(v), body);
    if (signbit(v)) { buf[0] = '-'; strcpy(buf + 1, body); }
    else strcpy(buf, body);
}

static uint64_t rng_state = 0x2545F4914F6CDD1DULL;
static uint64_t xorshift64(void) {
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 7;
    rng_state ^= rng_state << 17;
    return rng_state;
}

int main(int argc, char **argv) {
    long N = argc > 1 ? atol(argv[1]) : 2000000;
    long parse_fail = 0, show_fail = 0, show_nonmin = 0;
    long parse_slow_used = 0, show_slow_used = 0;

    // 1) random bit patterns -> Double: round-trip fastShow(v) and
    //    compare to the exact formatter; also feed the formatted
    //    string back through both parsers and compare to v.
    for (long i = 0; i < N; i++) {
        uint64_t bits = xorshift64();
        double v; memcpy(&v, &bits, sizeof v);
        if (isnan(v)) continue; // nan != nan makes string comparison meaningless; skip

        const char *fast_buf = fastShowStr(v);
        char exact_buf[64];
        exact_show(v, exact_buf);
        if (strcmp(fast_buf, exact_buf) != 0) {
            if (show_fail < 20) printf("SHOW MISMATCH: bits=%016llx fast=%s exact=%s\n", (unsigned long long)bits, fast_buf, exact_buf);
            show_fail++;
        }

        double back_fast = idris2rc2_fastParseDouble(fast_buf);
        double back_exact = idris2rc2_parse_double(exact_buf);
        uint64_t bf, be;
        memcpy(&bf, &back_fast, sizeof bf);
        memcpy(&be, &back_exact, sizeof be);
        if (bf != bits || be != bits) {
            if (parse_fail < 20) printf("ROUNDTRIP MISMATCH: bits=%016llx back_fast=%016llx back_exact=%016llx\n", (unsigned long long)bits, (unsigned long long)bf, (unsigned long long)be);
            parse_fail++;
        }
    }

    // 2) random decimal strings -> Double: compare fast vs exact parse directly.
    for (long i = 0; i < N; i++) {
        char s[40];
        int len = 0;
        if (xorshift64() & 1) s[len++] = '-';
        int intdigits = 1 + (int)(xorshift64() % 18);
        for (int j = 0; j < intdigits; j++) s[len++] = (char)('0' + xorshift64() % 10);
        if (xorshift64() & 1) {
            s[len++] = '.';
            int fracdigits = 1 + (int)(xorshift64() % 18);
            for (int j = 0; j < fracdigits; j++) s[len++] = (char)('0' + xorshift64() % 10);
        }
        if ((xorshift64() % 4) == 0) {
            s[len++] = 'e';
            if (xorshift64() & 1) s[len++] = '-';
            int edigits = 1 + (int)(xorshift64() % 3);
            for (int j = 0; j < edigits; j++) s[len++] = (char)('0' + xorshift64() % 10);
        }
        s[len] = '\0';

        double f = idris2rc2_fastParseDouble(s);
        double e = idris2rc2_parse_double(s);
        uint64_t bf, be;
        memcpy(&bf, &f, sizeof bf);
        memcpy(&be, &e, sizeof be);
        if (bf != be) {
            if (parse_fail < 40) printf("PARSE MISMATCH: s=%s fast=%016llx exact=%016llx\n", s, (unsigned long long)bf, (unsigned long long)be);
            parse_fail++;
        }
    }

    // 3) known hard/edge cases
    double edge_vals[] = {
        0.0, -0.0, 1.0, -1.0, 0.5, 2.0, 100.0, 1e300, 1e-300, 4.9e-324,
        1.7976931348623157e308, 2.2250738585072014e-308, 9007199254740993.0,
        123456789.123456, 0.1, 0.2, 0.3, 1.0/3.0,
    };
    for (size_t i = 0; i < sizeof(edge_vals)/sizeof(edge_vals[0]); i++) {
        double v = edge_vals[i];
        const char *fast_buf = fastShowStr(v);
        char exact_buf[64];
        exact_show(v, exact_buf);
        printf("EDGE v=%.20g fast=%s exact=%s %s\n", v, fast_buf, exact_buf, strcmp(fast_buf,exact_buf)==0 ? "OK" : "MISMATCH");
        if (strcmp(fast_buf, exact_buf) != 0) show_fail++;
    }

    printf("N=%ld parse_fail=%ld show_fail=%ld\n", N, parse_fail, show_fail);
    (void)parse_slow_used; (void)show_slow_used; (void)show_nonmin;
    return (parse_fail || show_fail) ? 1 : 0;
}
