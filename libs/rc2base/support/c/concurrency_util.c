#define _GNU_SOURCE

#include "concurrency_util.h"
#include "rc2/runtime.h"
#include "rc2/util.h"

#include <time.h>
#include <unistd.h>

void *idris2rc2_mutex_make(void) {
  IDRIS2RC2_Value *v = idris2rc2_alloc(sizeof(IDRIS2RC2_Mutex));
  v->header.tag = IDRIS2RC2_TAG_MUTEX;
  pthread_mutex_init(&((IDRIS2RC2_Mutex *)v)->mutex, NULL);
  return v;
}

void idris2rc2_mutex_acquire(IDRIS2RC2_Value *mutex) {
  pthread_mutex_lock(&((IDRIS2RC2_Mutex *)mutex)->mutex);
}

void idris2rc2_mutex_release(IDRIS2RC2_Value *mutex) {
  pthread_mutex_unlock(&((IDRIS2RC2_Mutex *)mutex)->mutex);
}

void *idris2rc2_condition_make(void) {
  IDRIS2RC2_Value *v = idris2rc2_alloc(sizeof(IDRIS2RC2_Condition));
  v->header.tag = IDRIS2RC2_TAG_CONDITION;
  pthread_cond_init(&((IDRIS2RC2_Condition *)v)->cond, NULL);
  return v;
}

void idris2rc2_condition_wait(IDRIS2RC2_Value *cond, IDRIS2RC2_Value *mutex) {
  pthread_cond_wait(&((IDRIS2RC2_Condition *)cond)->cond, &((IDRIS2RC2_Mutex *)mutex)->mutex);
}

void idris2rc2_condition_wait_timeout(IDRIS2RC2_Value *cond, IDRIS2RC2_Value *mutex, int64_t microseconds) {
  struct timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  ts.tv_sec += microseconds / 1000000;
  ts.tv_nsec += (microseconds % 1000000) * 1000;
  if (ts.tv_nsec >= 1000000000) {
    ts.tv_nsec -= 1000000000;
    ts.tv_sec += 1;
  }
  pthread_cond_timedwait(&((IDRIS2RC2_Condition *)cond)->cond, &((IDRIS2RC2_Mutex *)mutex)->mutex, &ts);
}

void idris2rc2_condition_signal(IDRIS2RC2_Value *cond) {
  pthread_cond_signal(&((IDRIS2RC2_Condition *)cond)->cond);
}

void idris2rc2_condition_broadcast(IDRIS2RC2_Value *cond) {
  pthread_cond_broadcast(&((IDRIS2RC2_Condition *)cond)->cond);
}

int64_t idris2rc2_get_thread_id(void) {
  return (int64_t)gettid();
}

static _Thread_local IDRIS2RC2_Value *idris2rc2_threadLocalData = NULL;

// prim__setThreadData's `{a : Type}` is NOT erased by rc2's codegen --
// the generated call passes it as a real leading argument (confirmed by
// building and reading the generated C), so `typeWitness` here is
// received-and-ignored, not actually absent.
void idris2rc2_set_thread_data(IDRIS2RC2_Value *typeWitness, IDRIS2RC2_Value *val) {
  IDRIS2RC2_Value *old = idris2rc2_threadLocalData;
  idris2rc2_threadLocalData = val;
  idris2rc2_drop(old);
}

// prim__getThreadData's `(a : Type)` argument is likewise a real
// (received-and-ignored) parameter, not erased.
IDRIS2RC2_Value *idris2rc2_get_thread_data(IDRIS2RC2_Value *typeWitness) {
  return idris2rc2_dup(idris2rc2_threadLocalData);
}

void *idris2rc2_semaphore_make(int64_t init) {
  IDRIS2RC2_Value *v = idris2rc2_alloc(sizeof(IDRIS2RC2_Semaphore));
  v->header.tag = IDRIS2RC2_TAG_SEMAPHORE;
  sem_init(&((IDRIS2RC2_Semaphore *)v)->sem, 0, (unsigned int)init);
  return v;
}

void idris2rc2_semaphore_post(IDRIS2RC2_Value *sema) {
  sem_post(&((IDRIS2RC2_Semaphore *)sema)->sem);
}

void idris2rc2_semaphore_wait(IDRIS2RC2_Value *sema) {
  sem_wait(&((IDRIS2RC2_Semaphore *)sema)->sem);
}

void *idris2rc2_barrier_make(int64_t numThreads) {
  IDRIS2RC2_Value *v = idris2rc2_alloc(sizeof(IDRIS2RC2_Barrier));
  v->header.tag = IDRIS2RC2_TAG_BARRIER;
  pthread_barrier_init(&((IDRIS2RC2_Barrier *)v)->barrier, NULL, (unsigned int)numThreads);
  return v;
}

void idris2rc2_barrier_wait(IDRIS2RC2_Value *barrier) {
  pthread_barrier_wait(&((IDRIS2RC2_Barrier *)barrier)->barrier);
}

// Mirrors ioprims.c's idris2rc2_fork trampoline (apply the erased %World
// token once to run a PrimIO a), except the result is returned through
// pthread_join's own out-parameter instead of being dropped -- this
// thread is joined, not detached, so the caller collects the value.
static void *idris2rc2_joinThreadTrampoline(void *arg) {
  return idris2rc2_applyClosure((IDRIS2RC2_Value *)arg, NULL);
}

// prim__forkJoin : (1 prog : PrimIO a) -> PrimIO (JoinHandle a) -- `a`
// appears in the return type, so (like setThreadData/getThreadData
// above) rc2's codegen passes its type witness as a real leading
// argument, received-and-ignored here.
void *idris2rc2_fork_join(IDRIS2RC2_Value *typeWitness, IDRIS2RC2_Closure *fct) {
  // Same use-after-free reasoning as idris2rc2_fork: the generated FFI
  // wrapper drops its own reference to fct right after this call
  // returns, but the spawned thread keeps using the pointer.
  idris2rc2_dup((IDRIS2RC2_Value *)fct);
  IDRIS2RC2_Value *v = idris2rc2_alloc(sizeof(IDRIS2RC2_JoinHandle));
  v->header.tag = IDRIS2RC2_TAG_JOINHANDLE;
  IDRIS2RC2_JoinHandle *h = (IDRIS2RC2_JoinHandle *)v;
  h->joined = false;
  int err = pthread_create(&h->tid, NULL, idris2rc2_joinThreadTrampoline, fct);
  IDRIS2RC2_VERIFY(err == 0, "pthread_create failed: %d", err);
  return v;
}

// prim__join : JoinHandle a -> PrimIO a -- same reasoning, `a`'s type
// witness precedes the real `handle` argument.
IDRIS2RC2_Value *idris2rc2_join(IDRIS2RC2_Value *typeWitness, IDRIS2RC2_Value *handle) {
  IDRIS2RC2_JoinHandle *h = (IDRIS2RC2_JoinHandle *)handle;
  void *result;
  pthread_join(h->tid, &result);
  h->joined = true;
  return (IDRIS2RC2_Value *)result;
}
