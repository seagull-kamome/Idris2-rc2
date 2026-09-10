// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

#include <locale.h>

#include "Test82RuntimeLocale.h"

char const *idris2rc2_test82_ctype(void) {
    return setlocale(LC_CTYPE, NULL);
}

char const *idris2rc2_test82_numeric(void) {
    return setlocale(LC_NUMERIC, NULL);
}
