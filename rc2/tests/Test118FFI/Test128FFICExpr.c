// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

// `C:` twins of Test118FFI/FFICExpr's `CExpr:` declarations: same
// result, written as functions, so real RefC (which has no `CExpr:`)
// can run the section.

#include "Test128FFICExpr.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>

int32_t idris2rc2_test128_ocreat(void) { return O_CREAT; }
int32_t idris2rc2_test128_einval(void) { return EINVAL; }
int32_t idris2rc2_test128_intmax(void) { return INT_MAX; }
int64_t idris2rc2_test128_mul(int64_t a, int64_t b) { return a * b; }
int64_t idris2rc2_test128_second(int64_t a, int64_t b) { return b; }
int64_t idris2rc2_test128_max2(int64_t a, int64_t b) { return (a > b ? a : b); }
int64_t idris2rc2_test128_max3(int64_t a, int64_t b, int64_t c)
{
    return IDRIS2RC2_TEST128_MAX(IDRIS2RC2_TEST128_MAX(a, b), c);
}
int64_t idris2rc2_test128_litlen(int64_t a) { return strlen("x,(y)") + a; }
int64_t idris2rc2_test128_isseparator(char c) { return c == ',' || c == ')'; }
int64_t idris2rc2_test128_twicelen(const char *s) { return strlen(s) + strlen(s); }
int64_t idris2rc2_test128_dollar(void) { return sizeof("$"); }
int64_t idris2rc2_test128_u8plus(uint8_t a) { return a + 1; }
double idris2rc2_test128_twice(double a) { return a * 2.0; }
int64_t idris2rc2_test128_sum10(int64_t a1, int64_t a2, int64_t a3, int64_t a4, int64_t a5,
                                int64_t a6, int64_t a7, int64_t a8, int64_t a9, int64_t a10)
{
    return a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + a9 + a10 * a10;
}
