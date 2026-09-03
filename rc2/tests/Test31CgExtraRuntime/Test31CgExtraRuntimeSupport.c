// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

// Injected via `%cg rc2 extraRuntime=...` (Test31CgExtraRuntime.idr) --
// not a real standalone translation unit, no #include guard needed:
// spliced as raw text into rc2's own generated .c, right after its
// own `#include <idris2rc2_runtime.h>`.

#include <stdint.h>

int64_t idris2rc2_test31_extra_double(int64_t x) {
    return x * 2;
}
