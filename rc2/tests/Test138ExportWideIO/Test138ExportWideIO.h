// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

// Companion header for Test138ExportWideIO.idr. The `extern`s are
// rc2-generated %export wrappers; `idris2rc2_test138_run` is the companion
// .c's own driver, called back into Idris via %foreign.

#include <stdint.h>

extern int64_t idris2rc2_test138_wide_io(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);
extern int64_t idris2rc2_test138_wide_pure(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);
extern int64_t idris2rc2_test138_narrow_io(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);
int64_t idris2rc2_test138_run(int64_t which);
