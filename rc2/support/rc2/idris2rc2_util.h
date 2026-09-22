#pragma once

#include <stdatomic.h>
#include <stdnoreturn.h>

// Lightweight spinlock (CAS loop, no syscall on the uncontended path) for
// protecting a short critical section -- e.g. an IORef's/Array's slot
// swap-and-drop, where a real pthread_mutex_t would be overkill and a
// bare atomic load+dup is unsafe (a concurrent writer's drop can free the
// old value between the reader's load and its dup; making the pointer
// swap itself atomic doesn't fix that -- see rc2/doc/concurrency.md).
// Not a substitute for pthread_mutex_t/_cond_t where a thread needs to
// actually block (Mutex/Condition/Semaphore/Barrier/Channel) -- spinning
// is only appropriate for a section this short.
static inline void idris2rc2_spin_lock(atomic_flag *lock) {
  while (atomic_flag_test_and_set_explicit(lock, memory_order_acquire)) {
    // busy-wait
  }
}

static inline void idris2rc2_spin_unlock(atomic_flag *lock) {
  atomic_flag_clear_explicit(lock, memory_order_release);
}

#define IDRIS2RC2_VERIFY(cond, ...)                                                \
  do {                                                                       \
    if (!(cond)) {                                                           \
      idris2rc2_verify_failed(__FILE__, __LINE__, #cond, __VA_ARGS__);             \
    }                                                                        \
  } while (0)

noreturn void idris2rc2_verify_failed(const char *file, int line, const char *cond,
                                 const char *fmt, ...)
#if defined(__clang__) || defined(__GNUC__)
    __attribute__((format(printf, 4, 5)))
#endif
    ;
