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

void *idris2rc2_test84_make_size(int64_t w, int64_t h) {
    test_size *s = malloc(sizeof(test_size));
    s->w = w;
    s->h = h;
    return s;
}

void *idris2rc2_test84_make_pair(double a, double b) {
    test_pair *p = malloc(sizeof(test_pair));
    p->a = a;
    p->b = b;
    return p;
}

void idris2rc2_test84_free_point(void *p) {
    free(p);
}
