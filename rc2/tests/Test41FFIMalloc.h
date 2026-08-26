// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

// Companion helpers for Test41FFIMalloc.idr: base's own System.FFI
// only exposes malloc/free at the Idris level (no generic peek/poke
// on a raw AnyPtr), so these two functions write/read a single byte
// through the pointer System.FFI.malloc itself returns, to prove it's
// a real, usable, writable allocation and not just an opaque handle.

void idris2rc2_test41_poke_byte(void *p, int val);
int idris2rc2_test41_peek_byte(void *p);
