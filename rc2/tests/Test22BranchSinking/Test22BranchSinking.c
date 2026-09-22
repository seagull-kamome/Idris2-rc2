// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

// Companion C implementation for Test22BranchSinking.idr's own
// %foreign declarations -- establishes the "test22_pair" struct name
// (Compiler.RC2.Emit's own StructDefs table) via a real constructor/
// destructor pair, mirroring Test24CStructSupport.c's own pattern.

#include <stdint.h>
#include <stdlib.h>

typedef struct { int64_t x; int64_t y; } test22_pair;

void *idris2rc2_test22_make_pair(int64_t x, int64_t y) {
    test22_pair *p = malloc(sizeof(test22_pair));
    p->x = x;
    p->y = y;
    return p;
}

void idris2rc2_test22_free_pair(void *p) {
    free(p);
}
