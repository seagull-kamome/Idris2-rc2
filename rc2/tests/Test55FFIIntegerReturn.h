// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

// `result` (the Integer return value's own out-parameter) is always
// the *first* parameter, matching GMP's own convention (`rop` always
// leads: `mpz_add(rop, op1, op2)`, `mpz_set_str(rop, str, base)`,
// etc.) -- see Compiler.RC2.EmitUtil's own packCFType CFInteger case.

#include <gmp.h>
#include <stdint.h>

void idris2rc2_test55_fromDecimalString(mpz_t result, const char *s);
void idris2rc2_test55_fromDecimalStringIO(mpz_t result, const char *s);
void idris2rc2_test55_addInt(mpz_t result, mpz_t x, int64_t y);
void idris2rc2_test55_addIntIO(mpz_t result, mpz_t x, int64_t y);
