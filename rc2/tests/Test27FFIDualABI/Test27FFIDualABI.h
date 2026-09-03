// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

#include <stdint.h>

int64_t idris2rc2_test27_add(int64_t a, int64_t b);
uint64_t idris2rc2_test27_scaleBits64(uint64_t x, uint64_t factor);
int32_t idris2rc2_test27_scaleInt32(int32_t x, int32_t factor);
double idris2rc2_test27_mulDouble(double a, double b);
int64_t idris2rc2_test27_mixed(int64_t n, const char *tag);
void idris2rc2_test27_noop(int64_t n);
char idris2rc2_test27_bumpChar(char c);

// absorbed from former Test50FFIInlineNoWorker.h
int64_t idris2rc2_test50_add(int64_t a, int64_t b);
int64_t idris2rc2_test50_mixed(int64_t n, const char *tag);
void idris2rc2_test50_noop(int64_t n);
char idris2rc2_test50_bumpChar(char c);
