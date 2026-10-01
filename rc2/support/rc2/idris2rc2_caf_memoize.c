#include "idris2rc2_caf_memoize.h"

#include <stdio.h>
#include <stdlib.h>

_Thread_local char idris2rc2_memo_self;

_Noreturn void idris2rc2_memo_cycle(void) {
  // Its own message, without a source line, so a test can expect it.
  fprintf(stderr, "idris2rc2: a top-level value depends on itself\n");
  exit(1);
}

// Process-wide, one node per memoized Boxed CAF -- built up by
// idris2rc2_memo_boxed_store (a lock-free push, same shape as any other
// Treiber-stack CAS loop), drained once by idris2rc2_memo_boxed_dropAll
// at idris2rc2_rtFinish.
static idris2rc2_memo_boxed *_Atomic idris2rc2_memo_boxed_cleanupHead = NULL;

void idris2rc2_memo_boxed_store(idris2rc2_memo_boxed *memo, IDRIS2RC2_Value *value) {
  memo->value = idris2rc2_dup(value);
  idris2rc2_memo_boxed *old =
      atomic_load_explicit(&idris2rc2_memo_boxed_cleanupHead, memory_order_relaxed);
  do {
    memo->cleanup_next = old;
  } while (!atomic_compare_exchange_weak_explicit(
      &idris2rc2_memo_boxed_cleanupHead, &old, memo,
      memory_order_release, memory_order_relaxed));
  atomic_store_explicit(&memo->done, true, memory_order_release);
}

IDRIS2RC2_Value *idris2rc2_memo_boxed_wait(idris2rc2_memo_boxed *memo) {
  while (!atomic_load_explicit(&memo->done, memory_order_acquire)) {
    if (atomic_load_explicit(&memo->owner, memory_order_relaxed) == &idris2rc2_memo_self)
      idris2rc2_memo_cycle();
    // busy-wait
  }
  return idris2rc2_dup(memo->value);
}

void idris2rc2_memo_boxed_dropAll(void) {
  idris2rc2_memo_boxed *node =
      atomic_load_explicit(&idris2rc2_memo_boxed_cleanupHead, memory_order_relaxed);
  while (node != NULL) {
    idris2rc2_memo_boxed *next = node->cleanup_next;
    idris2rc2_drop(node->value);
    node = next;
  }
}
