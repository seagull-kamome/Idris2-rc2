// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

#include "Test47ConstCFStringReturn.h"

// A real const char*-returning C function -- e.g. curl_easy_strerror's
// own shape -- that a CFString-returning %foreign wrapper declared as
// plain (non-const) `char *` would collide with under -Werror
// (-Wdiscarded-qualifiers). Returns a string literal (static storage,
// never freed, never mutated) precisely because that's the realistic
// shape of a real const-returning C API: rc2's own wrapper must copy it
// via idris2rc2_mkString rather than ever writing through the pointer.
const char *idris2rc2_test47_greeting(void) { return "hello from const char *"; }
