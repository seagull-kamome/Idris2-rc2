// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

// Companion C implementation for Test55FFIIntegerReturn.idr's own
// %foreign declarations. `result` is always a fresh, already-`mpz_init`'d
// mpz_t the Idris side allocated -- see Compiler.RC2.EmitUtil's own
// packCFType CFInteger case.

#include "Test55FFIIntegerReturn.h"

void idris2rc2_test55_fromDecimalString(const char *s, mpz_t result) {
    mpz_set_str(result, s, 10);
}

void idris2rc2_test55_fromDecimalStringIO(const char *s, mpz_t result) {
    mpz_set_str(result, s, 10);
}

void idris2rc2_test55_addInt(mpz_t x, int64_t y, mpz_t result) {
    mpz_add_ui(result, x, (unsigned long)y);
}

void idris2rc2_test55_addIntIO(mpz_t x, int64_t y, mpz_t result) {
    mpz_add_ui(result, x, (unsigned long)y);
}
