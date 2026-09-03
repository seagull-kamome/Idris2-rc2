// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

// void*-typed on purpose, same reasoning as Test24CStructSupport.h:
// rc2's own generated C already typedefs "test_point" itself
// (Compiler.RC2.Emit's StructDefs, populated from the %foreign
// make/free declarations below) -- declaring the same struct shape
// again here would trip a duplicate-typedef error once both headers
// are visible in the same translation unit.

#include <stdint.h>

void *idris2rc2_test61_make_point(int64_t x, double y);
void idris2rc2_test61_free_point(void *p);
int64_t idris2rc2_test61_run_check(void);

// %export wrappers (rc2-generated, not defined in this file).
extern int64_t idris2rc2_test61_get_x(void *p);
extern void *idris2rc2_test61_scale_point(void *p);
