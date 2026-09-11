// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

// Companion C implementation for Test84CgExternStruct.idr's own
// %foreign declarations -- see Test84CgExternStruct.h's own comment
// for why this file's own "test_point" typedef is the real one, not a
// void*-hiding workaround.

#include "Test84CgExternStruct.h"

#include <stdlib.h>

void *idris2rc2_test84_make_point(int64_t x, double y) {
    test_point *p = malloc(sizeof(test_point));
    p->x = x;
    p->y = y;
    return p;
}

void idris2rc2_test84_free_point(void *p) {
    free(p);
}
