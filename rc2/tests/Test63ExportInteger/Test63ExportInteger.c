// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

// Companion driver for Test63ExportInteger.idr's own `%export`ed
// `idris2rc2_test63_add` -- builds both operands directly via GMP and
// compares the result with `mpz_cmp`, no Idris/rc2 API involved.

#include "Test63ExportInteger.h"

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
