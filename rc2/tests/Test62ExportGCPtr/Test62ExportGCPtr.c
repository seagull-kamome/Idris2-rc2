// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

// Companion C implementation for Test62ExportGCPtr.idr's own
// %foreign declaration, plus the driver for its `%export`ed
// `idris2rc2_test62_read_byte` -- called as plain C, no Idris/rc2 API
// involved.

#include "Test62ExportGCPtr.h"

#include <stdlib.h>

int64_t idris2rc2_test62_peek_byte(void *p) {
    return (int64_t)(unsigned char)(((char *)p)[0]);
}

int64_t idris2rc2_test62_run_check(void) {
    char *buf = malloc(1);
    buf[0] = 99;
    int64_t v = idris2rc2_test62_read_byte(buf);
    free(buf);
    return v == 99;
}
