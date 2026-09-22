// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

// void*-typed on purpose -- same reason as Test24CStructSupport.h's
// own comment: rc2's own generated C already typedefs "test22_pair"
// itself from the Struct type's own field list, so declaring the same
// shape again here would trip a duplicate-typedef error once both
// headers are visible in the same translation unit.

#include <stdint.h>

void *idris2rc2_test22_make_pair(int64_t x, int64_t y);
void idris2rc2_test22_free_pair(void *p);
