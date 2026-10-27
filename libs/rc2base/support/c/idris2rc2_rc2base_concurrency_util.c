#define _GNU_SOURCE

#include "idris2rc2_rc2base_concurrency_util.h"
#include "idris2rc2_rt.h"
#include "idris2rc2_util.h"

#include <errno.h>
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

// A condition variable whose timed waits run on CLOCK_MONOTONIC: a deadline made
// from CLOCK_REALTIME stretches or shrinks when the system clock is set.
static void init_monotonic_cond(pthread_cond_t *cond) {
  pthread_condattr_t attr;
  pthread_condattr_init(&attr);
  pthread_condattr_setclock(&attr, CLOCK_MONOTONIC);
  pthread_cond_init(cond, &attr);
  pthread_condattr_destroy(&attr);
}

// The time `microseconds` from now on CLOCK_MONOTONIC (a negative count is now).
static struct timespec monotonic_deadline(int64_t microseconds) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  if (microseconds > 0) {
    ts.tv_sec += microseconds / 1000000;
    ts.tv_nsec += (microseconds % 1000000) * 1000;
    if (ts.tv_nsec >= 1000000000) {
      ts.tv_nsec -= 1000000000;
      ts.tv_sec += 1;
    }
  }
  return ts;
}

void *idris2rc2_condition_make(void) {
  IDRIS2RC2_Value *v = idris2rc2_alloc(sizeof(IDRIS2RC2_Condition));
  v->header.tag = IDRIS2RC2_TAG_CONDITION;
  init_monotonic_cond(&((IDRIS2RC2_Condition *)v)->cond);
  return v;
}

void idris2rc2_condition_wait(IDRIS2RC2_Value *cond, IDRIS2RC2_Value *mutex) {
  pthread_cond_wait(&((IDRIS2RC2_Condition *)cond)->cond, &((IDRIS2RC2_Mutex *)mutex)->mutex);
}

void idris2rc2_condition_wait_timeout(IDRIS2RC2_Value *cond, IDRIS2RC2_Value *mutex, int64_t microseconds) {
  struct timespec ts = monotonic_deadline(microseconds);
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

// The per-thread value lives under a pthread key, so that its destructor drops
// what is left when a thread exits (a `_Thread_local` would leak one value per
// thread). The main thread never runs it; the process ends anyway.
static pthread_key_t idris2rc2_threadDataKey;
static pthread_once_t idris2rc2_threadDataOnce = PTHREAD_ONCE_INIT;

static void idris2rc2_dropThreadData(void *v) {
  idris2rc2_drop((IDRIS2RC2_Value *)v);
}

static void idris2rc2_makeThreadDataKey(void) {
  int err = pthread_key_create(&idris2rc2_threadDataKey, idris2rc2_dropThreadData);
  IDRIS2RC2_VERIFY(err == 0, "pthread_key_create failed: %d", err);
}

void idris2rc2_set_thread_data(IDRIS2RC2_Value *, IDRIS2RC2_Value *val) {
  pthread_once(&idris2rc2_threadDataOnce, idris2rc2_makeThreadDataKey);
  IDRIS2RC2_Value *old = pthread_getspecific(idris2rc2_threadDataKey);
  // The generated FFI wrapper drops its own reference to val right after
  // this call returns (as idris2rc2_channel_put below), so the slot needs
  // its own.
  pthread_setspecific(idris2rc2_threadDataKey, idris2rc2_dup(val));
  idris2rc2_drop(old);
}

// prim__getThreadData's `(a : Type)` argument is likewise a real
// (received-and-ignored) parameter, not erased.
IDRIS2RC2_Value *idris2rc2_get_thread_data(IDRIS2RC2_Value *) {
  pthread_once(&idris2rc2_threadDataOnce, idris2rc2_makeThreadDataKey);
  return idris2rc2_dup(pthread_getspecific(idris2rc2_threadDataKey));
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
void *idris2rc2_fork_join(IDRIS2RC2_Value *, IDRIS2RC2_Closure *fct) {
  idris2rc2_enableMultiThreading();
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
IDRIS2RC2_Value *idris2rc2_join(IDRIS2RC2_Value *, IDRIS2RC2_Value *handle) {
  IDRIS2RC2_JoinHandle *h = (IDRIS2RC2_JoinHandle *)handle;
  // The result goes to the first caller; a second pthread_join on the same
  // thread is undefined behaviour, so stop with a message instead.
  IDRIS2RC2_VERIFY(!h->joined, "join: the thread was already joined");
  void *result;
  pthread_join(h->tid, &result);
  h->joined = true;
  return (IDRIS2RC2_Value *)result;
}

void *idris2rc2_channel_make(IDRIS2RC2_Value *) {
  IDRIS2RC2_Value *v = idris2rc2_alloc(sizeof(IDRIS2RC2_Channel));
  v->header.tag = IDRIS2RC2_TAG_CHANNEL;
  IDRIS2RC2_Channel *c = (IDRIS2RC2_Channel *)v;
  pthread_mutex_init(&c->mutex, NULL);
  init_monotonic_cond(&c->cond);
  c->head = NULL;
  c->tail = NULL;
  return v;
}

void idris2rc2_channel_put(IDRIS2RC2_Value *, IDRIS2RC2_Value *chan, IDRIS2RC2_Value *val) {
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

IDRIS2RC2_Value *idris2rc2_channel_get(IDRIS2RC2_Value *, IDRIS2RC2_Value *chan) {
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

// idris2rc2_wrapJust (idris2rc2_memory.h) always *builds* a real
// Constructor for whatever payload it's handed -- never elides one --
// so a payload that's itself NULL-representable (e.g. `Just []`,
// `Just ()`) never collapses onto the same NULL as Nothing (the
// narrower, sound relative of the "unwrap Just x to x" idea TODO.md
// records as investigated and dropped, for that exact reason).
#define idris2rc2_channel_wrap_just idris2rc2_wrapJust

IDRIS2RC2_Value *idris2rc2_channel_get_non_blocking(IDRIS2RC2_Value *, IDRIS2RC2_Value *chan) {
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

IDRIS2RC2_Value *idris2rc2_channel_get_with_timeout(IDRIS2RC2_Value *, IDRIS2RC2_Value *chan, int64_t milliseconds) {
  IDRIS2RC2_Channel *c = (IDRIS2RC2_Channel *)chan;
  struct timespec ts = monotonic_deadline(milliseconds * 1000);
  pthread_mutex_lock(&c->mutex);
  // A wake-up with nothing in the channel is not the end of the time: wait on,
  // for the deadline, until a value comes or the time is out.
  while (!c->head) {
    if (pthread_cond_timedwait(&c->cond, &c->mutex, &ts) == ETIMEDOUT)
      break;
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
