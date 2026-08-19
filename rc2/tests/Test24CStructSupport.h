// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

// void*-typed on purpose: rc2's own generated C already typedefs
// "test_point" itself (Compiler.RC2.Emit's Part C, see
// rc2/doc/c-struct-support.md) from the Struct type's own field list --
// declaring the same struct shape again here (even identically) trips
// a duplicate-typedef error from the C compiler once both headers are
// visible in the same translation unit.

#include <stdint.h>

void *idris2rc2_test24_make_point(int64_t x, double y);
void idris2rc2_test24_free_point(void *p);
