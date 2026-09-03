// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

// Companion driver for Test65ExportStringArg.idr's own `%export`ed
// `idris2rc2_test65_strlen` -- no Idris/rc2 API involved. Passes a
// plain string literal (static storage, never Idris/rc2-managed) and
// keeps using it, unmodified, after the call returns, proving rc2's
// own argument-side copy never aliases or frees the caller's buffer.

#include "Test65ExportStringArg.h"

#include <string.h>

int64_t idris2rc2_test65_run_check(void) {
    const char *lit = "hello!";
    int64_t len = idris2rc2_test65_strlen(lit);
    int64_t stillIntact = (strcmp(lit, "hello!") == 0);
    return (len == 6) && stillIntact;
}
