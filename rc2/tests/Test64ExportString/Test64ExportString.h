// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

#include <stdint.h>

// %export wrapper (rc2-generated, not defined in this file) -- a plain,
// independently-allocated `char *` buffer, not an IDRIS2RC2_String and
// not const (unlike CFString's usual %foreign-return convention, see
// Test47ConstCFStringReturn) -- the caller owns it and must free() it
// themselves; never pass it to any idris2rc2_* function.
extern char *idris2rc2_test64_greet(int64_t n);

int64_t idris2rc2_test64_run_check(void);
