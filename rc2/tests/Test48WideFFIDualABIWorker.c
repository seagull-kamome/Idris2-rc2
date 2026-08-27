// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

// Companion C implementation for Test48WideFFIDualABIWorker.idr's own
// %foreign declaration -- a 15-parameter function (12 native-eligible
// Ints + 3 Boxed Strings), standing in for a real C library binding
// wide enough to exercise Compiler.RC2.DualABI's Stage 3c FFI worker
// synthesis past the old MaxExtractFunArgs-based exclusion.

#include "Test48WideFFIDualABIWorker.h"
#include <string.h>

int64_t idris2rc2_test48_wide(
    int64_t a, int64_t b, int64_t c, int64_t d, int64_t e, int64_t f,
    int64_t g, int64_t h, int64_t i, int64_t j, int64_t k, int64_t l,
    const char *s1, const char *s2, const char *s3) {
    int64_t sum = a + b + c + d + e + f + g + h + i + j + k + l;
    int64_t lens = (int64_t)strlen(s1) + (int64_t)strlen(s2) + (int64_t)strlen(s3);
    return sum + lens;
}
