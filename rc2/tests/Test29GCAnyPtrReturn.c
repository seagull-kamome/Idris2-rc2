// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

#include <stdlib.h>

void *idris2rc2_test29_alloc(void) {
    long *p = malloc(sizeof(long));
    *p = 42;
    return p;
}

long idris2rc2_test29_read(void *p) {
    return *(long *)p;
}

void idris2rc2_test29_free(void *p) {
    free(p);
}
