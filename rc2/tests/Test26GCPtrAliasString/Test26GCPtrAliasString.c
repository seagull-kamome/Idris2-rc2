// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

// idris2rc2_test26_read_str mimics upstream idris_support.c's own
// idris2_getString(void *p) { return (char *)p; } -- a %foreign
// function returning a pointer INTO its own GCAnyPtr-owned argument's
// memory, no copy. See Test26GCPtrAliasString.idr's own doc comment
// for what this exercises.

#include <stdlib.h>

void *idris2rc2_test26_alloc(void) {
    char *p = malloc(4);
    p[0] = 'h';
    p[1] = 'i';
    p[2] = '\0';
    return p;
}

void idris2rc2_test26_free(void *p) {
    free(p);
}

char *idris2rc2_test26_read_str(void *p) {
    return (char *)p;
}

// idris2rc2_test29_* absorbed from former Test29GCAnyPtrReturn.c --
// see Test26GCPtrAliasString.idr's own doc comment for what this
// exercises (packCFType's CFGCPtr case).

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
