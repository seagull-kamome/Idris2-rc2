#pragma once

// Value representation for the rc2 backend runtime.
//
// Every heap value starts with a small header carrying an atomic
// reference count and a type tag. Small fixed-width integers/Char are
// represented unboxed, packed into the pointer itself (tagged pointers),
// exactly like a plain pointer with its low bit set so it can never be
// confused with a real (word-aligned) heap pointer.
//
// This design targets 64-bit (LP64) platforms only: an unboxed payload of
// up to 32 bits is packed into the upper bits of the pointer word, leaving
// the low 2 bits free for tagging.

#include <gmp.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define IDRIS2RC2_TAG_NONE 0
#define IDRIS2RC2_TAG_BITS32 3
#define IDRIS2RC2_TAG_BITS64 4
#define IDRIS2RC2_TAG_INT32 7
#define IDRIS2RC2_TAG_INT64 8
#define IDRIS2RC2_TAG_INTEGER 9
#define IDRIS2RC2_TAG_DOUBLE 10
#define IDRIS2RC2_TAG_STRING 12
#define IDRIS2RC2_TAG_CLOSURE 15
#define IDRIS2RC2_TAG_CONSTRUCTOR 17
#define IDRIS2RC2_TAG_IOREF 20
#define IDRIS2RC2_TAG_ARRAY 21
#define IDRIS2RC2_TAG_POINTER 22
#define IDRIS2RC2_TAG_GCPOINTER 23
#define IDRIS2RC2_TAG_BUFFER 24

typedef struct {
  // Values that reach the maximum reference count are treated as immortal
  // (never freed). This also covers statically-allocated values.
#define IDRIS2RC2_REFCOUNT_MAX UINT16_MAX
  _Atomic uint16_t refCount;
  uint8_t tag;
  uint8_t reserved;
} IDRIS2RC2_Header;

#define IDRIS2RC2_STOCKVAL(t) {IDRIS2RC2_REFCOUNT_MAX, (t), 0}

typedef struct {
  IDRIS2RC2_Header header;
  // Payload follows, depending on `header.tag` (see IDRIS2RC2_* structs below).
} IDRIS2RC2_Value;

// bit0 set => unboxed scalar payload packed into the pointer word itself.
#define idris2rc2_is_unboxed(p) ((uintptr_t)(p)&3)
#define idris2rc2_unbox_shift 32

#define idris2rc2_to_i64(p) (((IDRIS2RC2_Int64 *)(p))->v)
#define idris2rc2_to_u64(p) (((IDRIS2RC2_Bits64 *)(p))->v)
#define idris2rc2_to_u32(p) ((uint32_t)((uintptr_t)(p) >> idris2rc2_unbox_shift))
#define idris2rc2_to_i32(p) ((int32_t)((uintptr_t)(p) >> idris2rc2_unbox_shift))
#define idris2rc2_to_u16(p) ((uint16_t)((uintptr_t)(p) >> idris2rc2_unbox_shift))
#define idris2rc2_to_i16(p) ((int16_t)((uintptr_t)(p) >> idris2rc2_unbox_shift))
#define idris2rc2_to_u8(p) ((uint8_t)((uintptr_t)(p) >> idris2rc2_unbox_shift))
#define idris2rc2_to_i8(p) ((int8_t)((uintptr_t)(p) >> idris2rc2_unbox_shift))
#define idris2rc2_to_char(p) ((uint32_t)((uintptr_t)(p) >> idris2rc2_unbox_shift))
#define idris2rc2_to_bool(p) (idris2rc2_to_i8(p))
#define idris2rc2_to_double(p) (((IDRIS2RC2_Double *)(p))->v)

typedef struct {
  IDRIS2RC2_Header header;
  uint32_t v;
} IDRIS2RC2_Bits32;
typedef struct {
  IDRIS2RC2_Header header;
  uint64_t v;
} IDRIS2RC2_Bits64;
typedef struct {
  IDRIS2RC2_Header header;
  int32_t v;
} IDRIS2RC2_Int32;
typedef struct {
  IDRIS2RC2_Header header;
  int64_t v;
} IDRIS2RC2_Int64;
typedef struct {
  IDRIS2RC2_Header header;
  mpz_t v;
} IDRIS2RC2_Integer;
typedef struct {
  IDRIS2RC2_Header header;
  double v;
} IDRIS2RC2_Double;
typedef struct {
  IDRIS2RC2_Header header;
  char *str; // NUL-terminated, UTF-8 bytes; indexing is byte-based
} IDRIS2RC2_String;

typedef struct {
  IDRIS2RC2_Header header;
  int32_t arity;
  int32_t tag; // -1 if this constructor is identified by name instead
  char const *name;
  IDRIS2RC2_Value *args[];
} IDRIS2RC2_Constructor;

// A zero-argument, tagged data constructor other than Nil/Nothing/Z/
// MkUnit (those four are represented as a bare NULL instead, matched by
// NULL-vs-non-NULL -- see Compiler.RC2.Emit's RCon/RConCase) has no
// fields to store, so it's represented the same way as any other small
// unboxed scalar: its own tag packed into a tagged pointer (see
// RCEmptyCon in Compiler.RC2.RCExp), never a real IDRIS2RC2_Constructor
// allocation. A scrutinee of such a type can therefore be *either* a
// tagged pointer or a real heap IDRIS2RC2_Constructor* depending on
// which alternative it happens to hold at runtime, so any tag-based
// dispatch (Compiler.RC2.Emit's RConCase) must check is_unboxed first
// rather than always dereferencing as a heap object.
#define idris2rc2_conTag(p) (idris2rc2_is_unboxed(p) ? (int32_t)idris2rc2_to_u32(p) : ((IDRIS2RC2_Constructor *)(p))->tag)

typedef struct {
  IDRIS2RC2_Header header;
  void *fn; // cast to the right arity's function pointer type to call
  uint8_t arity;
  uint8_t filled;
  IDRIS2RC2_Value *args[];
} IDRIS2RC2_Closure;

typedef struct {
  IDRIS2RC2_Header header;
  IDRIS2RC2_Value *v;
} IDRIS2RC2_IORef;

typedef struct {
  IDRIS2RC2_Header header;
  void *p;
} IDRIS2RC2_Pointer;

typedef struct {
  IDRIS2RC2_Header header;
  IDRIS2RC2_Pointer *p;
  IDRIS2RC2_Closure *onCollect;
} IDRIS2RC2_GCPointer;

typedef struct {
  IDRIS2RC2_Header header;
  int capacity;
  IDRIS2RC2_Value **items;
} IDRIS2RC2_Array;

// Wraps a raw malloc'd buffer.c allocation (see IDRIS2RC2_RawBuffer in
// buffer.h) so it participates in refcounting like any other heap value;
// freed via idris2rc2_teardown's IDRIS2RC2_TAG_BUFFER case (memory.c).
typedef struct {
  IDRIS2RC2_Header header;
  void *buf;
} IDRIS2RC2_Buffer;
