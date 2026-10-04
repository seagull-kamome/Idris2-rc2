#pragma once

#include "idris2rc2_datatypes.h"
#include "idris2rc2_util.h"

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

// Switches every refcount update to atomic operations for good; called
// before any thread other than the first can touch an Idris value
// (rc2/doc/hybrid-refcount.md).
void idris2rc2_enableMultiThreading(void);
int idris2rc2_isMultiThreaded(void);

// Plain refcount updates until the program goes multi-threaded, atomic
// from then on: rc2/doc/hybrid-refcount.md.
extern bool idris2rc2_threaded;

// Drops one reference; true if it was the last, so the caller tears the
// object down. Once threaded, the acquire before that is a load, not
// atomic_thread_fence: ThreadSanitizer does not model fences and reports
// every such teardown as a race.
static inline bool idris2rc2_rc_release(IDRIS2RC2_Header *h) {
  if (__builtin_expect(idris2rc2_threaded, 0)) {
    uint16_t c = atomic_load_explicit(&h->refCount, memory_order_relaxed);
    if (c == IDRIS2RC2_REFCOUNT_MAX ||
	atomic_fetch_sub_explicit(&h->refCount, 1, memory_order_release) != 1)
      return false;
    (void)atomic_load_explicit(&h->refCount, memory_order_acquire);
    return true;
  }
  uint16_t c = h->rc;
  if (c == IDRIS2RC2_REFCOUNT_MAX) return false;
  h->rc = (uint16_t)(c - 1);
  return c == 1;
}

// Increments the refcount of `v` (a no-op for unboxed/NULL/immortal values)
// and returns it, so it can be used inline: `x = idris2rc2_dup(y);`
static inline IDRIS2RC2_Value *idris2rc2_dup(IDRIS2RC2_Value *v) {
  if (v && !idris2rc2_is_unboxed(v)) {
    if (__builtin_expect(idris2rc2_threaded, 0)) {
      uint16_t c =
	  atomic_load_explicit(&v->header.refCount, memory_order_relaxed);
      if (c != IDRIS2RC2_REFCOUNT_MAX)
	atomic_fetch_add_explicit(&v->header.refCount, 1, memory_order_relaxed);
      return v;
    }
    if (v->header.rc != IDRIS2RC2_REFCOUNT_MAX) v->header.rc++;
  }

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
    if (!idris2rc2_threaded) {
      uint16_t cur = v->header.rc;
      if (cur != IDRIS2RC2_REFCOUNT_MAX)
	v->header.rc = cur > IDRIS2RC2_REFCOUNT_MAX - n ? IDRIS2RC2_REFCOUNT_MAX
							: (uint16_t)(cur + n);
      return v;
    }
    uint16_t cur =
	atomic_load_explicit(&v->header.refCount, memory_order_relaxed);
    while (cur != IDRIS2RC2_REFCOUNT_MAX) {
      uint16_t next = cur > IDRIS2RC2_REFCOUNT_MAX - n ? IDRIS2RC2_REFCOUNT_MAX
						       : (uint16_t)(cur + n);
      if (atomic_compare_exchange_weak_explicit(&v->header.refCount, &cur, next,
						memory_order_relaxed,
						memory_order_relaxed))
	break;
    }
  }
  return v;
}

// Decrements the refcount of `v`, freeing it (recursively) once it reaches
// zero. A no-op for unboxed/NULL/immortal values.
static inline void idris2rc2_drop(IDRIS2RC2_Value *v) {
  if (v && !idris2rc2_is_unboxed(v) && idris2rc2_rc_release(&v->header))
    idris2rc2_teardown(v);
}
// Unconditionally deallocates `v` right now, with no refcount check at
// all -- the RFree IR primitive's lowering. Only ever safe to call on a
// value statically proven to be a brand-new, unshared allocation (see
// RCExp.idr/RC.idr's module notes on RFree). A no-op for unboxed/NULL.
void idris2rc2_free(IDRIS2RC2_Value *v);

IDRIS2RC2_Constructor *idris2rc2_newConstructor(int arity, int tag);
IDRIS2RC2_Closure *idris2rc2_mkClosure(IDRIS2RC2_Value *(*fn)(), uint8_t arity,
				       uint8_t filled);

// Prelude.Maybe's Just is always tag=1, arity=1 -- confirmed empirically
// (not by reading the compiler's own source) by building a small
// Maybe-returning program and reading the generated C: an ordinary
// `Just x` lowers to `idris2rc2_newConstructor(1, 1)`, and ConstFold's
// Prelude.Maybe is one fixed, versioned library type shared by every
// rc2 program, not a per-program user-defined ADT whose tag assignment
// varies; would break if a future Idris2 ever reordered Nothing/Just's
// declaration. Takes ownership of `val` (stores it directly, no dup) --
// same convention as idris2rc2_newConstructor's own callers elsewhere.
// Nothing itself needs no equivalent helper: Compiler.RC2.Emit's own
// RCon/RConCase represent it as a bare NULL, never a real allocation
// (see idris2rc2_conTag's own doc comment, datatypes.h).
IDRIS2RC2_Value *idris2rc2_wrapJust(IDRIS2RC2_Value *val);

IDRIS2RC2_Value *idris2rc2_mkDouble(double d);

#define idris2rc2_mkChar(x) \
  ((IDRIS2RC2_Value *)(((uintptr_t)(uint32_t)(x) << idris2rc2_unbox_shift) + 1))
#define idris2rc2_mkBits8(x) \
  ((IDRIS2RC2_Value *)(((uintptr_t)(uint8_t)(x) << idris2rc2_unbox_shift) + 1))
#define idris2rc2_mkBits16(x) \
  ((IDRIS2RC2_Value *)(((uintptr_t)(uint16_t)(x) << idris2rc2_unbox_shift) + 1))
#define idris2rc2_mkBits32(x) \
  ((IDRIS2RC2_Value *)(((uintptr_t)(uint32_t)(x) << idris2rc2_unbox_shift) + 1))
#define idris2rc2_mkInt8(x)                             \
  ((IDRIS2RC2_Value *)(((uintptr_t)(uint8_t)(int8_t)(x) \
			<< idris2rc2_unbox_shift) +     \
		       1))
#define idris2rc2_mkInt16(x)                              \
  ((IDRIS2RC2_Value *)(((uintptr_t)(uint16_t)(int16_t)(x) \
			<< idris2rc2_unbox_shift) +       \
		       1))
#define idris2rc2_mkInt32(x)                              \
  ((IDRIS2RC2_Value *)(((uintptr_t)(uint32_t)(int32_t)(x) \
			<< idris2rc2_unbox_shift) +       \
		       1))
#define idris2rc2_mkBool(x) (idris2rc2_mkInt8(x))

IDRIS2RC2_Value *idris2rc2_mkBits64(uint64_t i);
IDRIS2RC2_Value *idris2rc2_mkInt64(int64_t i);

// Aborts if `n` can't fit `len`'s own uint32_t (datatypes.h) -- shared by
// every String constructor/concatenation that sums or measures a byte
// count, so an oversized result fails loudly instead of silently
// wrapping into a corrupt, too-short `len`.
static inline uint32_t idris2rc2_checkedStrLen(size_t n) {
  IDRIS2RC2_VERIFY(n <= UINT32_MAX, "string too large (%zu bytes)", n);
  return (uint32_t)n;
}

// bufLen includes the NUL. Sets len = bufLen - 1: the caller must fill
// exactly that many content bytes (embedded NUL allowed) -- the trailing
// byte at str[bufLen - 1] is already the terminator, left at '\0' by this
// function's own memset.
IDRIS2RC2_String *idris2rc2_mkEmptyString(size_t bufLen);
// strlen-based: for a plain C string with no embedded NUL (e.g. an
// external library's char* return).
IDRIS2RC2_String *idris2rc2_mkString(char const *s);
// Copies exactly `len` bytes of `s` (which may contain embedded NUL) and
// appends a NUL terminator.
IDRIS2RC2_String *idris2rc2_mkStringLen(char const *s, size_t len);

IDRIS2RC2_Pointer *idris2rc2_mkPointer(void *raw);
IDRIS2RC2_GCPointer *idris2rc2_mkGCPointer(void *raw,
					   IDRIS2RC2_Closure *onCollect);
IDRIS2RC2_ThreadID *idris2rc2_mkThreadID(pthread_t tid);
IDRIS2RC2_Array *idris2rc2_mkArray(int length);
// Wraps a raw buffer.c allocation (see buffer.h); takes ownership -- freed
// with a bare free() when the wrapper's refcount reaches zero.
IDRIS2RC2_Buffer *idris2rc2_mkBuffer(void *buf);

extern IDRIS2RC2_String const idris2rc2_emptyStringValue;

// Integer: an immediate (the Int64 layout) when it lies in
// [IDRIS2RC2_IMM_I64_MIN, IDRIS2RC2_IMM_I64_LIMIT), a boxed mpz otherwise
// -- never a boxed mpz for a value that fits (rc2/doc/immediate-ints.md).
_Static_assert(GMP_NUMB_BITS == 64,
	       "an immediate Integer is viewed as one GMP limb");
IDRIS2RC2_Integer *idris2rc2_mkInteger(void);
IDRIS2RC2_Value *idris2rc2_mkIntegerLiteral(char const *digits);
IDRIS2RC2_Value *idris2rc2_mkIntegerFromMpz(mpz_srcptr src);
IDRIS2RC2_Value *idris2rc2_mkIntegerBoxedI64(int64_t n);
IDRIS2RC2_Value *idris2rc2_mkIntegerBoxedU64(uint64_t n);
IDRIS2RC2_Value *idris2rc2_integerNormalize(IDRIS2RC2_Integer *r);

static inline IDRIS2RC2_Value *idris2rc2_mkIntegerI64(int64_t n) {
  if (n >= IDRIS2RC2_IMM_I64_MIN && n < IDRIS2RC2_IMM_I64_LIMIT)
    return IDRIS2RC2_IMM_INT64(n);
  return idris2rc2_mkIntegerBoxedI64(n);
}
static inline IDRIS2RC2_Value *idris2rc2_mkIntegerU64(uint64_t n) {
  if (n < (uint64_t)IDRIS2RC2_IMM_I64_LIMIT) return IDRIS2RC2_IMM_INT64(n);
  return idris2rc2_mkIntegerBoxedU64(n);
}

// Stack storage letting an immediate Integer be read as a read-only mpz.
typedef struct {
  __mpz_struct z;
  mp_limb_t limb;
} IDRIS2RC2_IntegerView;

static inline mpz_srcptr idris2rc2_integerView(IDRIS2RC2_Value *x,
					       IDRIS2RC2_IntegerView *buf) {
  if (!idris2rc2_is_unboxed(x)) return ((IDRIS2RC2_Integer *)x)->v;
  int64_t n = idris2rc2_imm_signed(x);
  buf->limb = n < 0 ? -(uint64_t)n : (uint64_t)n;
  return mpz_roinit_n(&buf->z, &buf->limb, n < 0 ? -1 : 1);
}
