// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

// Companion C implementation -- establishes the "test_point" struct
// name (same pattern as Test24CStructSupport.c) and drives the two
// `%export`ed wrappers Test61ExportStruct.idr declares, as plain C, no
// Idris/rc2 API involved.

#include "Test61ExportStruct.h"

#include <stdlib.h>

typedef struct { int64_t x; double y; } test_point;

void *idris2rc2_test61_make_point(int64_t x, double y) {
    test_point *p = malloc(sizeof(test_point));
    p->x = x;
    p->y = y;
    return p;
}

void idris2rc2_test61_free_point(void *p) {
    free(p);
}

int64_t idris2rc2_test61_run_check(void) {
    void *p = idris2rc2_test61_make_point(7, 2.5);
    int64_t x = idris2rc2_test61_get_x(p);
    void *p2 = idris2rc2_test61_scale_point(p);
    int64_t ok = (x == 7) && (p2 == p);
    idris2rc2_test61_free_point(p);
    return ok;
}
