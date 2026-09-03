// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

// Calls Test59ExportScalar.idr's own %export'd `idris2rc2_test_add`/
// `idris2rc2_test_scale` directly as plain C functions -- no Idris/rc2
// API involved at all -- to prove the wrapper rc2 generates is a
// genuinely callable native-C-ABI entry point, not merely a name that
// happens to exist in the same translation unit.

#include "Test59ExportScalar.h"

int64_t idris2rc2_test_call_exports_from_c(int64_t seed) {
    int64_t a = idris2rc2_test_add(seed, 7);
    double s = idris2rc2_test_scale((double)seed, 2.0);
    return a + (int64_t)s;
}
