// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

// Like Test84CgExternStruct.h, a real typedef this file's own
// companion .c genuinely uses -- but with a `const char *` field
// (`name`), the one shape Test84's own all-numeric struct never
// exercised: RStructGet's own field-access cast (Emit.idr) has to
// discard that `const` on purpose to hand the value to
// idris2rc2_mkString. `data` is a second, plain (non-const) pointer
// field -- idris2curl_test85_make_point (the companion .c) sets it to
// the exact same address as `name`, so reading both back and
// confirming they agree is this test's own correctness check, not
// just a compile check.

#include <stdint.h>

typedef struct { int64_t id; const char *name; void *data; } wide_point;

void *idris2rc2_test85_make_point(int64_t id, const char *name);
void idris2rc2_test85_free_point(void *p);
