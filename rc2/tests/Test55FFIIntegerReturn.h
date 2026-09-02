// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

// `result` (the Integer return value's own out-parameter) is always
// the *last* parameter -- Compiler.RC2.Emit appends it after every
// ordinary argument, not GMP's own usual rop-first convention.

#include <gmp.h>
#include <stdint.h>

void idris2rc2_test55_fromDecimalString(const char *s, mpz_t result);
void idris2rc2_test55_fromDecimalStringIO(const char *s, mpz_t result);
void idris2rc2_test55_addInt(mpz_t x, int64_t y, mpz_t result);
void idris2rc2_test55_addIntIO(mpz_t x, int64_t y, mpz_t result);
