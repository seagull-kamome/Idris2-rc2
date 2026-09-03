// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

#include <gmp.h>
#include <stdint.h>

// %export wrapper (rc2-generated, not defined in this file) -- `out`
// (the Integer return value's own out-parameter) is the *first*
// parameter, matching GMP's own convention (see Test54FFIInteger.h).
extern void idris2rc2_test63_add(mpz_t out, mpz_t x, mpz_t y);

int64_t idris2rc2_test63_run_check(void);
