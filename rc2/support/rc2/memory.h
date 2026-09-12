#pragma once

#include "datatypes.h"

IDRIS2RC2_Value *idris2rc2_alloc(size_t size);
#define IDRIS2RC2_NEW(t) ((t *)idris2rc2_alloc(sizeof(t)))

// EXPERIMENTAL: idris2rc2_dup/idris2rc2_dup_n/idris2rc2_drop's own hot
// path (the atomic refcount check/adjust itself) is defined here as
// `static inline`, not as an ordinary out-of-line function in memory.c,
// so that a program's own generated .c file -- which #includes this
// header -- sees the plain atomic instructions directly rather than an
// opaque call across a translation-unit boundary into the prebuilt
// libidris2rc2.a. An opaque call is a real, avoidable cost on top of the
// atomic RMW itself: call/ret overhead, argument/return register
// shuffling per the calling convention, and -- the bigger effect for a
// run of several back-to-back dup/drop calls on *different* variables
// (e.g. reading several fields out of one destructured constructor) --
// the compiler can never reorder or overlap the latency of separate
// opaque calls the way it can with plain inlined instructions, even
// though no single hardware instruction can atomically touch more than
// one memory location at once (there is no cross-address equivalent of
// idris2rc2_dup_n's own single-address batching). idris2rc2_teardown
// (the actual per-tag cleanup, reached only once a value's last
// reference is actually dropped) stays a real out-of-line call in
// memory.c -- it is the cold path, not worth inlining or duplicating
// into every translation unit.
void idris2rc2_teardown(IDRIS2RC2_Value *v);

// Increments the refcount of `v` (a no-op for unboxed/NULL/immortal values)
// and returns it, so it can be used inline: `x = idris2rc2_dup(y);`
static inline IDRIS2RC2_Value *idris2rc2_dup(IDRIS2RC2_Value *v) {
  if (v && !idris2rc2_is_unboxed(v) && v->header.refCount != IDRIS2RC2_REFCOUNT_MAX)
    atomic_fetch_add_explicit(&v->header.refCount, 1, memory_order_relaxed);
  return v;
}

// Batched form of idris2rc2_dup: increments v's refcount by `n` (n >= 1)
// in a single atomic add, equivalent in effect to n separate
// idris2rc2_dup(v) calls but without their repeated per-call branch and
// atomic-op overhead. Same no-op conditions as idris2rc2_dup (unboxed/
// NULL/immortal). See Compiler.RC2.RCExp's RDup and its own `extra`
// field for the IR-level source of a batched increment.
static inline IDRIS2RC2_Value *idris2rc2_dup_n(IDRIS2RC2_Value *v, int n) {
  if (v && !idris2rc2_is_unboxed(v)) {
    // Unlike idris2rc2_dup's own single +1 (which can only ever land
    // exactly on REFCOUNT_MAX before freezing there, never past it), a
    // plain atomic_fetch_add(n) here could overshoot REFCOUNT_MAX and
    // wrap the uint16_t back to a small value, silently losing the
    // object's immortal/shared status -- a CAS loop clamps to
    // REFCOUNT_MAX instead of ever adding past it.
    uint16_t cur = atomic_load_explicit(&v->header.refCount, memory_order_relaxed);
    while (cur != IDRIS2RC2_REFCOUNT_MAX) {
      uint16_t next = cur > IDRIS2RC2_REFCOUNT_MAX - n
                        ? IDRIS2RC2_REFCOUNT_MAX : (uint16_t)(cur + n);
      if (atomic_compare_exchange_weak_explicit(&v->header.refCount, &cur, next,
              memory_order_relaxed, memory_order_relaxed))
        break;
    }
  }
  return v;
}

// Decrements the refcount of `v`, freeing it (recursively) once it reaches
// zero. A no-op for unboxed/NULL/immortal values.
static inline void idris2rc2_drop(IDRIS2RC2_Value *v) {
  if (!v || idris2rc2_is_unboxed(v))
    return;
  if (v->header.refCount == IDRIS2RC2_REFCOUNT_MAX)
    return; // immortal
  if (atomic_fetch_sub_explicit(&v->header.refCount, 1, memory_order_release) != 1)
    return;
  atomic_thread_fence(memory_order_acquire);
  idris2rc2_teardown(v);
}
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
