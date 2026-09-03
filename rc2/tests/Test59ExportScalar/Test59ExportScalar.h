// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

#include <stdint.h>

// Prototypes for the two %export wrappers Test59ExportScalar.idr
// declares -- these symbols are rc2-generated (Compiler.RC2.Emit's
// emitExportWrapper), not defined anywhere in this companion .c file;
// declaring them `extern` here is exactly what a real external C
// caller of an %export'd Idris function would do.
extern int64_t idris2rc2_test_add(int64_t, int64_t);
extern double idris2rc2_test_scale(double, double);

int64_t idris2rc2_test_call_exports_from_c(int64_t seed);
