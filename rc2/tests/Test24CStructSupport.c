// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

// Companion C implementation for Test24CStructSupport.idr's own
// %foreign declarations -- establishes the "test_point" struct name
// (Compiler.RC2.Emit's own StructDefs table, see
// rc2/doc/c-struct-support.md) via a real constructor/destructor pair,
// the same way an actual C library binding would. Its own local
// "test_point" typedef exists only so this file's own body can name
// the fields by index -- Test24CStructSupport.h deliberately exposes
// these two functions as void* (see its own comment) to avoid clashing
// with rc2's own generated typedef of the same name/shape.

#include <stdint.h>
#include <stdlib.h>

typedef struct { int64_t x; double y; } test_point;

void *idris2rc2_test24_make_point(int64_t x, double y) {
    test_point *p = malloc(sizeof(test_point));
    p->x = x;
    p->y = y;
    return p;
}

void idris2rc2_test24_free_point(void *p) {
    free(p);
}
