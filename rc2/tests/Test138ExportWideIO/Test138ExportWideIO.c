// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

// Companion C for Test138ExportWideIO.idr: calls the exported wrappers as plain
// C functions with the arguments 1, 2, 3, ...

#include "Test138ExportWideIO.h"

int64_t idris2rc2_test138_run(int64_t which) {
    switch (which) {
    case 0: return idris2rc2_test138_wide_io(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20);
    case 1: return idris2rc2_test138_wide_pure(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20);
    default: return idris2rc2_test138_narrow_io(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19);
    }
}
