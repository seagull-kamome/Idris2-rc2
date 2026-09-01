// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

// Companion C implementation for Test50FFIInlineNoWorker.idr's own
// %foreign declarations -- plain primitive-typed functions, standing
// in for a real C library binding, exercising the same set of CFType
// shapes as Test27FFIDualABI.idr's own companion (all-native args +
// native return, a mixed native/Boxed arg signature with a native
// return, a native arg with a Boxed (CFUnit) IO return, and a CFChar
// arg/return round trip) but through Compiler.RC2.DualABI's Stage 5
// inline path instead of a synthesized standalone FFI worker.

#include "Test50FFIInlineNoWorker.h"
#include <string.h>

int64_t idris2rc2_test50_add(int64_t a, int64_t b) {
    return a + b;
}

int64_t idris2rc2_test50_mixed(int64_t n, const char *tag) {
    return n + (int64_t)strlen(tag);
}

void idris2rc2_test50_noop(int64_t n) {
    (void)n;
}

char idris2rc2_test50_bumpChar(char c) {
    return (char)((unsigned char)c + 1);
}
