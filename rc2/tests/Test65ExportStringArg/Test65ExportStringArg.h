// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

#include <stdint.h>

// %export wrapper (rc2-generated, not defined in this file) -- takes a
// plain `const char *`; rc2 copies it into its own Idris-owned buffer
// (idris2rc2_mkString) before use, so the caller's own string is never
// aliased or freed by rc2 and remains valid/unmodified after the call.
extern int64_t idris2rc2_test65_strlen(const char *s);

int64_t idris2rc2_test65_run_check(void);
