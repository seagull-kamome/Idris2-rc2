// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

// Companion C implementation for Test27FFIDualABI.idr's own %foreign
// declarations -- plain primitive-typed functions, standing in for a
// real C library binding, exercising the dual-ABI FFI worker
// (Compiler.RC2.DualABI's ffiWorkerTable / Compiler.RC2.Emit's
// emitFFIWorker) across every CFType shape it distinguishes: all-
// native args + native return (idris2rc2_test27_add/scaleBits64/
// scaleInt32/mulDouble), a mixed native/Boxed arg signature with a native return
// (idris2rc2_test27_mixed), a native arg with a Boxed (CFUnit) IO
// return (idris2rc2_test27_noop), and a CFChar arg/return round trip
// (idris2rc2_test27_bumpChar) exercising the explicit uint32_t<->char
// cast a native CFChar position needs at this exact call boundary.

#include "Test27FFIDualABI.h"
#include <string.h>

int64_t idris2rc2_test27_add(int64_t a, int64_t b) {
    return a + b;
}

uint64_t idris2rc2_test27_scaleBits64(uint64_t x, uint64_t factor) {
    return x * factor;
}

int32_t idris2rc2_test27_scaleInt32(int32_t x, int32_t factor) {
    return x * factor;
}

double idris2rc2_test27_mulDouble(double a, double b) {
    return a * b;
}

int64_t idris2rc2_test27_mixed(int64_t n, const char *tag) {
    return n + (int64_t)strlen(tag);
}

void idris2rc2_test27_noop(int64_t n) {
    (void)n;
}

char idris2rc2_test27_bumpChar(char c) {
    return (char)((unsigned char)c + 1);
}
