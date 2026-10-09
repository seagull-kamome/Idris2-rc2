// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

#include "Test129CExprPriority.h"

// Wrong on purpose: a call to this means the `C:`/`RefC:` tag won over `CExpr:`.
int64_t idris2rc2_test129_priority(void) { return 999; }
