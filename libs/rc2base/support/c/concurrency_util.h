#ifndef CONCURRENCY_UTIL_H
#define CONCURRENCY_UTIL_H

#include "rc2/datatypes.h"
#include "rc2/memory.h"

void *idris2rc2_mutex_make(void);
void idris2rc2_mutex_acquire(IDRIS2RC2_Value *mutex);
void idris2rc2_mutex_release(IDRIS2RC2_Value *mutex);

void *idris2rc2_condition_make(void);
void idris2rc2_condition_wait(IDRIS2RC2_Value *cond, IDRIS2RC2_Value *mutex);
void idris2rc2_condition_wait_timeout(IDRIS2RC2_Value *cond, IDRIS2RC2_Value *mutex, int64_t microseconds);
void idris2rc2_condition_signal(IDRIS2RC2_Value *cond);
void idris2rc2_condition_broadcast(IDRIS2RC2_Value *cond);

int64_t idris2rc2_get_thread_id(void);
// The leading IDRIS2RC2_Value* on these two, and on idris2rc2_fork_join/
// idris2rc2_join below, is a type witness rc2's codegen passes whenever
// `a` is polymorphic in a %foreign declaration's signature (confirmed
// empirically -- not erased despite being implicit). Received and
// ignored throughout.
void idris2rc2_set_thread_data(IDRIS2RC2_Value *typeWitness, IDRIS2RC2_Value *val);
IDRIS2RC2_Value *idris2rc2_get_thread_data(IDRIS2RC2_Value *typeWitness);

void *idris2rc2_semaphore_make(int64_t init);
void idris2rc2_semaphore_post(IDRIS2RC2_Value *sema);
void idris2rc2_semaphore_wait(IDRIS2RC2_Value *sema);

void *idris2rc2_barrier_make(int64_t numThreads);
void idris2rc2_barrier_wait(IDRIS2RC2_Value *barrier);

void *idris2rc2_fork_join(IDRIS2RC2_Value *typeWitness, IDRIS2RC2_Closure *fct);
IDRIS2RC2_Value *idris2rc2_join(IDRIS2RC2_Value *typeWitness, IDRIS2RC2_Value *handle);

void *idris2rc2_channel_make(IDRIS2RC2_Value *typeWitness);
void idris2rc2_channel_put(IDRIS2RC2_Value *typeWitness, IDRIS2RC2_Value *chan, IDRIS2RC2_Value *val);
IDRIS2RC2_Value *idris2rc2_channel_get(IDRIS2RC2_Value *typeWitness, IDRIS2RC2_Value *chan);
IDRIS2RC2_Value *idris2rc2_channel_get_non_blocking(IDRIS2RC2_Value *typeWitness, IDRIS2RC2_Value *chan);
// prim__channelGetWithTimeout's Int is milliseconds (upstream's own
// channelGetWithTimeout wrapper casts its Nat milliseconds param
// straight through, no unit conversion) -- unlike
// idris2rc2_condition_wait_timeout above, which is microseconds.
IDRIS2RC2_Value *idris2rc2_channel_get_with_timeout(IDRIS2RC2_Value *typeWitness, IDRIS2RC2_Value *chan, int64_t milliseconds);

#endif
