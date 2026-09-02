#pragma once

// Backs System.FFI.C.Ptr (libs/rc2base) -- raw, unchecked memory access
// into any C pointer (`System.FFI.malloc`'d memory, a C struct field,
// anything a %foreign call hands back). `offset` is an element index,
// not a byte offset -- exactly like C's own `((ty *)p)[offset]` array
// indexing, which is exactly what these expand to. Header-only
// `static inline`, not a separate translation unit: %foreign call sites
// #include this header directly (same pattern as idris2rc2_text_index/
// idris2rc2_TextBuffer_unsafe_write_char below, text_util.h), so the
// cast+index is visible to the compiler at the call site and actually
// inlines instead of costing a real function call. Trades the strict-
// aliasing/alignment safety a memcpy-based version would have for that
// inlining -- deliberate, since this module's whole point is touching
// memory exactly the way a C program touching the same bytes would.
//
// No bounds checking: unlike Data.Buffer's IDRIS2RC2_RawBuffer, a bare
// pointer here carries no size to check against.
//
// Native byte order (unlike Data.Buffer's portable little-endian
// encoding) -- this module reads/writes real C memory layout, not a
// portable serialization format.

#include <stdint.h>

#define IDRIS2RC2_PTR_FETCH(name, ty)                                       \
  static inline ty name(void *p, int32_t offset) {                         \
    return ((ty *)p)[offset];                                              \
  }
#define IDRIS2RC2_PTR_STORE(name, ty)                                       \
  static inline void name(void *p, int32_t offset, ty val) {               \
    ((ty *)p)[offset] = val;                                               \
  }

IDRIS2RC2_PTR_FETCH(idris2rc2_ptr_fetch_u8, uint8_t)
IDRIS2RC2_PTR_STORE(idris2rc2_ptr_store_u8, uint8_t)
IDRIS2RC2_PTR_FETCH(idris2rc2_ptr_fetch_u16, uint16_t)
IDRIS2RC2_PTR_STORE(idris2rc2_ptr_store_u16, uint16_t)
IDRIS2RC2_PTR_FETCH(idris2rc2_ptr_fetch_u32, uint32_t)
IDRIS2RC2_PTR_STORE(idris2rc2_ptr_store_u32, uint32_t)
IDRIS2RC2_PTR_FETCH(idris2rc2_ptr_fetch_u64, uint64_t)
IDRIS2RC2_PTR_STORE(idris2rc2_ptr_store_u64, uint64_t)

IDRIS2RC2_PTR_FETCH(idris2rc2_ptr_fetch_i8, int8_t)
IDRIS2RC2_PTR_STORE(idris2rc2_ptr_store_i8, int8_t)
IDRIS2RC2_PTR_FETCH(idris2rc2_ptr_fetch_i16, int16_t)
IDRIS2RC2_PTR_STORE(idris2rc2_ptr_store_i16, int16_t)
IDRIS2RC2_PTR_FETCH(idris2rc2_ptr_fetch_i32, int32_t)
IDRIS2RC2_PTR_STORE(idris2rc2_ptr_store_i32, int32_t)
IDRIS2RC2_PTR_FETCH(idris2rc2_ptr_fetch_i64, int64_t)
IDRIS2RC2_PTR_STORE(idris2rc2_ptr_store_i64, int64_t)

IDRIS2RC2_PTR_FETCH(idris2rc2_ptr_fetch_f64, double)
IDRIS2RC2_PTR_STORE(idris2rc2_ptr_store_f64, double)

IDRIS2RC2_PTR_FETCH(idris2rc2_ptr_fetch_ptr, void *)
IDRIS2RC2_PTR_STORE(idris2rc2_ptr_store_ptr, void *)

#undef IDRIS2RC2_PTR_FETCH
#undef IDRIS2RC2_PTR_STORE

// Every function above also has a `GCPtr Bits8`-taking Idris-side
// counterpart (System.FFI.C.Ptr's own unsafeGCPtrFetch/unsafeGCPtrStore)
// declared against these exact same symbols -- a `GCPtr` %foreign
// argument already unwraps to the same raw pointer a plain `Ptr`
// argument would (Compiler.RC2.EmitUtil's extractValue CFGCPtr case),
// so no separate C entry point is needed for that direction.
