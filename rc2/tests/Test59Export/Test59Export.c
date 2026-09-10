// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

// Companion C for the merged %export suite Test59Export.idr. Each
// driver below calls the rc2-generated %export wrappers directly as
// plain C functions -- no Idris/rc2 API involved -- to prove each
// wrapper is a genuinely callable native-C-ABI entry point, not merely
// a name that happens to exist in the same translation unit.

#include "Test59Export.h"

#include <stdlib.h>
#include <string.h>

// ---- section 1: scalars ----
int64_t idris2rc2_test_call_exports_from_c(int64_t seed) {
    int64_t a = idris2rc2_test_add(seed, 7);
    double s = idris2rc2_test_scale((double)seed, 2.0);
    return a + (int64_t)s;
}

// ---- section 2: CFPtr round trip ----
int64_t idris2rc2_test60_run_check(void) {
    char *buf = malloc(4);
    buf[0] = 'X';
    void *out = idris2rc2_test60_identity(buf);
    int64_t ok = (out == (void *)buf) && (((char *)out)[0] == 'X');
    free(buf);
    return ok;
}

// ---- section 3: CFStruct by pointer ----
// Establishes the "test_point" struct name (same pattern as
// Test24CStructSupport.c).
typedef struct { int64_t x; double y; } test_point;

void *idris2rc2_test61_make_point(int64_t x, double y) {
    test_point *p = malloc(sizeof(test_point));
    p->x = x;
    p->y = y;
    return p;
}

void idris2rc2_test61_free_point(void *p) {
    free(p);
}

int64_t idris2rc2_test61_run_check(void) {
    void *p = idris2rc2_test61_make_point(7, 2.5);
    int64_t x = idris2rc2_test61_get_x(p);
    void *p2 = idris2rc2_test61_scale_point(p);
    int64_t ok = (x == 7) && (p2 == p);
    idris2rc2_test61_free_point(p);
    return ok;
}

// ---- section 4: CFGCPtr as an argument ----
int64_t idris2rc2_test62_peek_byte(void *p) {
    return (int64_t)(unsigned char)(((char *)p)[0]);
}

int64_t idris2rc2_test62_run_check(void) {
    char *buf = malloc(1);
    buf[0] = 99;
    int64_t v = idris2rc2_test62_read_byte(buf);
    free(buf);
    return v == 99;
}

// ---- section 5: CFInteger, both directions ----
int64_t idris2rc2_test63_run_check(void) {
    mpz_t a, b, expected, out;
    mpz_init_set_str(a, "123456789012345678901234567890", 10);
    mpz_init_set_str(b, "1", 10);
    mpz_init_set_str(expected, "123456789012345678901234567891", 10);
    mpz_init(out);

    idris2rc2_test63_add(out, a, b);
    int64_t ok = (mpz_cmp(out, expected) == 0);

    mpz_clear(a);
    mpz_clear(b);
    mpz_clear(expected);
    mpz_clear(out);
    return ok;
}

// ---- section 6: CFString return (caller owns / frees the buffer) ----
int64_t idris2rc2_test64_run_check(void) {
    char *s = idris2rc2_test64_greet(9);
    int64_t ok = (strcmp(s, "hello 9") == 0);
    free(s);
    return ok;
}

// ---- section 7: CFString argument (rc2 copies in) ----
int64_t idris2rc2_test65_run_check(void) {
    const char *lit = "hello!";
    int64_t len = idris2rc2_test65_strlen(lit);
    int64_t stillIntact = (strcmp(lit, "hello!") == 0);
    return (len == 6) && stillIntact;
}
