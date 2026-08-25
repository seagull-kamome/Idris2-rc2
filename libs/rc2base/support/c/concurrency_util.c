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

void *idris2rc2_channel_make(IDRIS2RC2_Value *typeWitness) {
  IDRIS2RC2_Value *v = idris2rc2_alloc(sizeof(IDRIS2RC2_Channel));
  v->header.tag = IDRIS2RC2_TAG_CHANNEL;
  IDRIS2RC2_Channel *c = (IDRIS2RC2_Channel *)v;
  pthread_mutex_init(&c->mutex, NULL);
  pthread_cond_init(&c->cond, NULL);
  c->head = NULL;
  c->tail = NULL;
  return v;
}

void idris2rc2_channel_put(IDRIS2RC2_Value *typeWitness, IDRIS2RC2_Value *chan, IDRIS2RC2_Value *val) {
  IDRIS2RC2_Channel *c = (IDRIS2RC2_Channel *)chan;
  idris2rc2_ChannelNode *node = malloc(sizeof(idris2rc2_ChannelNode));
  IDRIS2RC2_VERIFY(node, "malloc failed");
  node->next = NULL;
  // The generated FFI wrapper drops its own reference to every argument
  // (including val) right after this call returns -- same convention
  // idris2rc2_fork/idris2rc2_fork_join's own dup already documents --
  // but the node holding val outlives this call, so it needs its own
  // reference.
  node->value = idris2rc2_dup(val);
  pthread_mutex_lock(&c->mutex);
  if (c->tail)
    c->tail->next = node;
  else
    c->head = node;
  c->tail = node;
  pthread_cond_signal(&c->cond);
  pthread_mutex_unlock(&c->mutex);
}

IDRIS2RC2_Value *idris2rc2_channel_get(IDRIS2RC2_Value *typeWitness, IDRIS2RC2_Value *chan) {
  IDRIS2RC2_Channel *c = (IDRIS2RC2_Channel *)chan;
  pthread_mutex_lock(&c->mutex);
  while (!c->head)
    pthread_cond_wait(&c->cond, &c->mutex);
  idris2rc2_ChannelNode *node = c->head;
  c->head = node->next;
  if (!c->head)
    c->tail = NULL;
  pthread_mutex_unlock(&c->mutex);
  IDRIS2RC2_Value *val = node->value;
  free(node);
  return val;
}

// Prelude.Maybe's Just is always tag=1, arity=1 -- confirmed empirically
// (not by reading the compiler's own source) by building a small
// Maybe-returning program and reading the generated C: an ordinary
// `Just x` lowers to `idris2rc2_newConstructor(1, 1)`, and ConstFold's
// own staged-static `Just []` uses the same tag/arity. This is a
// narrower, sound relative of the "unwrap Just x to x" idea TODO.md
// records as investigated and dropped: that one was rejected because a
// payload that's itself NULL-representable (e.g. `Just []`, `Just ()`)
// would collapse onto the same NULL as Nothing. Here we always *build*
// a real Constructor for whatever payload we're handed -- we never
// elide one -- so that failure mode doesn't apply. Only safe because
// Prelude.Maybe is one fixed, versioned library type shared by every
// rc2 program, not a per-program user-defined ADT whose tag assignment
// varies; would break if a future Idris2 ever reordered Nothing/Just's
// declaration.
static IDRIS2RC2_Value *idris2rc2_channel_wrap_just(IDRIS2RC2_Value *val) {
  IDRIS2RC2_Constructor *just = idris2rc2_newConstructor(1, 1);
  just->args[0] = val;
  return (IDRIS2RC2_Value *)just;
}

IDRIS2RC2_Value *idris2rc2_channel_get_non_blocking(IDRIS2RC2_Value *typeWitness, IDRIS2RC2_Value *chan) {
  IDRIS2RC2_Channel *c = (IDRIS2RC2_Channel *)chan;
  pthread_mutex_lock(&c->mutex);
  idris2rc2_ChannelNode *node = c->head;
  if (node) {
    c->head = node->next;
    if (!c->head)
      c->tail = NULL;
  }
  pthread_mutex_unlock(&c->mutex);
  if (!node)
    return NULL;
  IDRIS2RC2_Value *val = node->value;
  free(node);
  return idris2rc2_channel_wrap_just(val);
}

IDRIS2RC2_Value *idris2rc2_channel_get_with_timeout(IDRIS2RC2_Value *typeWitness, IDRIS2RC2_Value *chan, int64_t milliseconds) {
  IDRIS2RC2_Channel *c = (IDRIS2RC2_Channel *)chan;
  pthread_mutex_lock(&c->mutex);
  if (!c->head) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += milliseconds / 1000;
    ts.tv_nsec += (milliseconds % 1000) * 1000000;
    if (ts.tv_nsec >= 1000000000) {
      ts.tv_nsec -= 1000000000;
      ts.tv_sec += 1;
    }
    pthread_cond_timedwait(&c->cond, &c->mutex, &ts);
  }
  idris2rc2_ChannelNode *node = c->head;
  if (node) {
    c->head = node->next;
    if (!c->head)
      c->tail = NULL;
  }
  pthread_mutex_unlock(&c->mutex);
  if (!node)
    return NULL;
  IDRIS2RC2_Value *val = node->value;
  free(node);
  return idris2rc2_channel_wrap_just(val);
}
