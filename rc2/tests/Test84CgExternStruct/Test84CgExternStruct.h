// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

// Unlike Test24CStructSupport's own companion header (void*-typed
// specifically to dodge a duplicate-typedef clash with rc2's own
// generated struct definition), this one declares the REAL
// "test_point" typedef itself -- the same shape a genuine system/
// library header would already provide. Test84CgExternStruct.idr's
// own `%cg rc2 externStruct=test_point` is what makes that safe (see
// its own header comment and rc2/doc/directives.md).

#include <stdint.h>

typedef struct { int64_t x; double y; } test_point;

void *idris2rc2_test84_make_point(int64_t x, double y);
void idris2rc2_test84_free_point(void *p);
