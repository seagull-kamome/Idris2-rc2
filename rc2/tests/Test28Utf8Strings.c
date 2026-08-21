// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

// Companion C implementation for Test28Utf8Strings.idr's own %foreign
// declaration -- a fixed byte sequence containing one lone UTF-8
// continuation byte (0x80), standing in for a String sourced from an
// untrusted external C function, exercising idris2rc2_utf8DecodeAt's
// own U+FFFD fallback rather than the well-formed UTF-8 every
// internally-constructed rc2 String is guaranteed to have.

#include "Test28Utf8Strings.h"

char *idris2rc2_test28_malformed(void) {
    static char s[] = {'a', 'b', (char)0x80, 'c', 'd', '\0'};
    return s;
}
