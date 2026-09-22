#pragma once

// Runtime backing for Compiler.RC2.RCExp's RMemoize -- see
// rc2/doc/caf-memoization.md for the full design. One
// idris2rc2_memo_boxed/idris2rc2_memo_native per memoized CAF, declared
// as a file-scope static by Compiler.RC2.Emit's own emitMemoizeInto.

#include "memory.h"

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

// `claimed`/`done` are two separate fields on purpose: an earlier design
// shared one field as both "already computed" flag and "next node in a
// global cleanup list", which made the very first CAF ever memoized in
// a program indistinguishable from "never computed" (its own cleanup-
// list link would be NULL, same as the not-yet-computed sentinel) --
// doc/caf-memoization.md's own "Emit-side C codegen" section.
typedef struct idris2rc2_memo_boxed {
  atomic_flag claimed;
  _Atomic bool done;
  IDRIS2RC2_Value *value;
  // Only ever written once, by whichever caller idris2rc2_memo_boxed_claim
  // returned true to, before that same caller publishes this node onto
  // idris2rc2_memo_boxed_cleanupHead via a release CAS (caf_memoize.c) --
  // no other thread can observe this node at all until that CAS
  // succeeds, so this field itself needs no atomicity of its own.
  struct idris2rc2_memo_boxed *cleanup_next;
} idris2rc2_memo_boxed;

#define IDRIS2RC2_MEMO_BOXED_INIT { ATOMIC_FLAG_INIT, false, NULL, NULL }

// True exactly once per `memo`, for whichever caller's own call happens
// to win the race -- that caller must then compute the CAF's own value
// and call idris2rc2_memo_boxed_store below. Every other caller (this
// returns false to) must instead call idris2rc2_memo_boxed_wait.
static inline bool idris2rc2_memo_boxed_claim(idris2rc2_memo_boxed *memo) {
  return !atomic_flag_test_and_set_explicit(&memo->claimed, memory_order_acquire);
}

// Stores a fresh dup of `value` as `memo`'s own permanent reference (the
// caller keeps using its own original, already-owned reference for its
// own immediate return -- this dup is `memo`'s, not the caller's),
// links `memo` onto the process-wide cleanup list
// (idris2rc2_memo_boxed_dropAll, called once from idris2rc2_rtFinish),
// then marks `memo` done. Only ever called once per `memo`.
void idris2rc2_memo_boxed_store(idris2rc2_memo_boxed *memo, IDRIS2RC2_Value *value);

// Spins until another thread's idris2rc2_memo_boxed_store finishes
// (same "spin, no portable pause instruction" tradeoff as
// idris2rc2_spin_lock, util.h), then returns a fresh dup of the
// now-ready value.
IDRIS2RC2_Value *idris2rc2_memo_boxed_wait(idris2rc2_memo_boxed *memo);

// Drops every boxed CAF's own permanent reference, across the whole
// process -- called once, from idris2rc2_rtFinish. Not thread-safe with
// concurrent idris2rc2_memo_boxed_store calls -- only valid at process
// teardown, after every other thread has already stopped.
void idris2rc2_memo_boxed_dropAll(void);

// Native (unboxed, unrefcounted) CAF value -- no dup/drop, no cleanup
// list (nothing to free). `value`'s three members cover every
// native-eligible PrimType (Compiler.RC2.Emit.Util's own nativeCType):
// every signed integer width and Char (unsigned, stored widened to
// uint32_t either way) fit in `i`/`u` respectively, Double in `d`.
typedef struct idris2rc2_memo_native {
  atomic_flag claimed;
  _Atomic bool done;
  union { int64_t i; uint64_t u; double d; } value;
} idris2rc2_memo_native;

#define IDRIS2RC2_MEMO_NATIVE_INIT { ATOMIC_FLAG_INIT, false, { 0 } }

static inline bool idris2rc2_memo_native_claim(idris2rc2_memo_native *memo) {
  return !atomic_flag_test_and_set_explicit(&memo->claimed, memory_order_acquire);
}

// Caller stores its own computed value into memo->value's own matching
// member itself, then calls this to publish it.
static inline void idris2rc2_memo_native_publish(idris2rc2_memo_native *memo) {
  atomic_store_explicit(&memo->done, true, memory_order_release);
}

static inline void idris2rc2_memo_native_wait(idris2rc2_memo_native *memo) {
  while (!atomic_load_explicit(&memo->done, memory_order_acquire)) {
    // busy-wait
  }
}
