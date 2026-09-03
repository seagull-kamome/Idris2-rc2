// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

// Companion driver for Test60ExportPtr.idr's own `%export`ed
// `idris2rc2_test60_identity` -- calls it as a plain C function, no
// Idris/rc2 API involved.

#include "Test60ExportPtr.h"

#include <stdlib.h>

int64_t idris2rc2_test60_run_check(void) {
    char *buf = malloc(4);
    buf[0] = 'X';
    void *out = idris2rc2_test60_identity(buf);
    int64_t ok = (out == (void *)buf) && (((char *)out)[0] == 'X');
    free(buf);
    return ok;
}
