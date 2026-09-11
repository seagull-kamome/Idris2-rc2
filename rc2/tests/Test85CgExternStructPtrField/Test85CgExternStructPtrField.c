// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

#include "Test85CgExternStructPtrField.h"

#include <stdlib.h>
#include <string.h>

void *idris2rc2_test85_make_point(int64_t id, const char *name) {
    wide_point *p = malloc(sizeof(wide_point));
    char *copy = strdup(name);
    p->id = id;
    p->name = copy;
    p->data = (void *) copy;
    return p;
}

void idris2rc2_test85_free_point(void *pp) {
    wide_point *p = (wide_point *) pp;
    free((void *) p->name);
    free(p);
}
