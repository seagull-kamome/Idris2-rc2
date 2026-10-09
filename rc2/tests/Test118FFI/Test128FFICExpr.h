// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

// Header for Test118FFI/FFICExpr: a macro the `CExpr:` declarations
// expand, and the `C:` twins (plain functions) of the other
// declarations, so the section also runs under real RefC.

#include <stdint.h>
#include <string.h>

#define IDRIS2RC2_TEST128_MAX(a, b) (((a) > (b)) ? (a) : (b))

int32_t idris2rc2_test128_ocreat(void);
int32_t idris2rc2_test128_einval(void);
int32_t idris2rc2_test128_intmax(void);
int64_t idris2rc2_test128_mul(int64_t a, int64_t b);
int64_t idris2rc2_test128_second(int64_t a, int64_t b);
int64_t idris2rc2_test128_max2(int64_t a, int64_t b);
int64_t idris2rc2_test128_max3(int64_t a, int64_t b, int64_t c);
int64_t idris2rc2_test128_litlen(int64_t a);
int64_t idris2rc2_test128_isseparator(char c);
int64_t idris2rc2_test128_twicelen(const char *s);
int64_t idris2rc2_test128_dollar(void);
int64_t idris2rc2_test128_u8plus(uint8_t a);
double idris2rc2_test128_twice(double a);
int64_t idris2rc2_test128_sum10(int64_t a1, int64_t a2, int64_t a3, int64_t a4, int64_t a5,
                                int64_t a6, int64_t a7, int64_t a8, int64_t a9, int64_t a10);
