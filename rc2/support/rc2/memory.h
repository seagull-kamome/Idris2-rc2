#pragma once

#include "datatypes.h"

IDRIS2RC2_Value *idris2rc2_alloc(size_t size);
#define IDRIS2RC2_NEW(t) ((t *)idris2rc2_alloc(sizeof(t)))

// Increments the refcount of `v` (a no-op for unboxed/NULL/immortal values)
// and returns it, so it can be used inline: `x = idris2rc2_dup(y);`
IDRIS2RC2_Value *idris2rc2_dup(IDRIS2RC2_Value *v);
// Decrements the refcount of `v`, freeing it (recursively) once it reaches
// zero. A no-op for unboxed/NULL/immortal values.
void idris2rc2_drop(IDRIS2RC2_Value *v);
// Unconditionally deallocates `v` right now, with no refcount check at
// all -- the RFree IR primitive's lowering. Only ever safe to call on a
// value statically proven to be a brand-new, unshared allocation (see
// RCExp.idr/RC.idr's module notes on RFree). A no-op for unboxed/NULL.
void idris2rc2_free(IDRIS2RC2_Value *v);

IDRIS2RC2_Constructor *idris2rc2_newConstructor(int arity, int tag);
IDRIS2RC2_Closure *idris2rc2_mkClosure(IDRIS2RC2_Value *(*fn)(), uint8_t arity, uint8_t filled);

IDRIS2RC2_Value *idris2rc2_mkDouble(double d);

#define idris2rc2_mkChar(x) ((IDRIS2RC2_Value *)(((uintptr_t)(uint32_t)(x) << idris2rc2_unbox_shift) + 1))
#define idris2rc2_mkBits8(x) ((IDRIS2RC2_Value *)(((uintptr_t)(uint8_t)(x) << idris2rc2_unbox_shift) + 1))
#define idris2rc2_mkBits16(x) ((IDRIS2RC2_Value *)(((uintptr_t)(uint16_t)(x) << idris2rc2_unbox_shift) + 1))
#define idris2rc2_mkBits32(x) ((IDRIS2RC2_Value *)(((uintptr_t)(uint32_t)(x) << idris2rc2_unbox_shift) + 1))
#define idris2rc2_mkInt8(x) ((IDRIS2RC2_Value *)(((uintptr_t)(uint8_t)(int8_t)(x) << idris2rc2_unbox_shift) + 1))
#define idris2rc2_mkInt16(x) ((IDRIS2RC2_Value *)(((uintptr_t)(uint16_t)(int16_t)(x) << idris2rc2_unbox_shift) + 1))
#define idris2rc2_mkInt32(x) ((IDRIS2RC2_Value *)(((uintptr_t)(uint32_t)(int32_t)(x) << idris2rc2_unbox_shift) + 1))
#define idris2rc2_mkBool(x) (idris2rc2_mkInt8(x))

IDRIS2RC2_Value *idris2rc2_mkBits64(uint64_t i);
IDRIS2RC2_Value *idris2rc2_mkInt64(int64_t i);

IDRIS2RC2_Integer *idris2rc2_mkInteger(void);
IDRIS2RC2_Value *idris2rc2_mkIntegerLiteral(char const *digits);
IDRIS2RC2_Integer *idris2rc2_mkIntegerFromMpz(mpz_t src);
IDRIS2RC2_String *idris2rc2_mkEmptyString(size_t bufLen); // bufLen includes the NUL
IDRIS2RC2_String *idris2rc2_mkString(char const *s);

IDRIS2RC2_Pointer *idris2rc2_mkPointer(void *raw);
IDRIS2RC2_GCPointer *idris2rc2_mkGCPointer(void *raw, IDRIS2RC2_Closure *onCollect);
IDRIS2RC2_ThreadID *idris2rc2_mkThreadID(pthread_t tid);
IDRIS2RC2_Array *idris2rc2_mkArray(int length);
// Wraps a raw buffer.c allocation (see buffer.h); takes ownership -- freed
// with a bare free() when the wrapper's refcount reaches zero.
IDRIS2RC2_Buffer *idris2rc2_mkBuffer(void *buf);

extern IDRIS2RC2_Int64 const idris2rc2_smallInt64[100];
extern IDRIS2RC2_Bits64 const idris2rc2_smallBits64[100];
extern IDRIS2RC2_Integer idris2rc2_smallInteger[100];
IDRIS2RC2_Value *idris2rc2_getSmallInteger(int n);
extern IDRIS2RC2_String const idris2rc2_emptyStringValue;
