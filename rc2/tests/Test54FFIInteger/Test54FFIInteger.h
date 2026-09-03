// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

#include <gmp.h>
#include <stdint.h>

char *idris2rc2_test54_toDecimalString(mpz_t x);

// absorbed from former Test55FFIIntegerReturn.h -- `result` (the
// Integer return value's own out-parameter) is always the *first*
// parameter, matching GMP's own convention.
void idris2rc2_test55_fromDecimalString(mpz_t result, const char *s);
void idris2rc2_test55_fromDecimalStringIO(mpz_t result, const char *s);
void idris2rc2_test55_addInt(mpz_t result, mpz_t x, int64_t y);
void idris2rc2_test55_addIntIO(mpz_t result, mpz_t x, int64_t y);
