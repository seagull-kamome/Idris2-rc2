// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

// Companion driver for Test64ExportString.idr's own `%export`ed
// `idris2rc2_test64_greet` -- no Idris/rc2 API involved; explicitly
// free()s the returned buffer itself, proving the ownership contract.

#include "Test64ExportString.h"

#include <stdlib.h>
#include <string.h>

int64_t idris2rc2_test64_run_check(void) {
    char *s = idris2rc2_test64_greet(9);
    int64_t ok = (strcmp(s, "hello 9") == 0);
    free(s);
    return ok;
}
