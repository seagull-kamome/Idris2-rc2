#include "memory.h"
#include "runtime.h"
#include "util.h"

#include <pthread.h>

IDRIS2RC2_Value *idris2rc2_alloc(size_t size) {
  size_t aligned = ((size + sizeof(void *) - 1) / sizeof(void *)) * sizeof(void *);
  IDRIS2RC2_Value *v;
#if defined(__STDC_VERSION__) && (__STDC_VERSION__ >= 201112L) &&            \
    !defined(__APPLE__) && !defined(_WIN32)
  v = (IDRIS2RC2_Value *)aligned_alloc(sizeof(void *), aligned);
#else
  v = (IDRIS2RC2_Value *)malloc(aligned);
#endif
  IDRIS2RC2_VERIFY(v && !idris2rc2_is_unboxed(v), "allocation failed");
  v->header.refCount = 1;
  v->header.tag = IDRIS2RC2_TAG_NONE;
  v->header.reserved = 0;
  return v;
}

IDRIS2RC2_Constructor *idris2rc2_newConstructor(int arity, int tag) {
  IDRIS2RC2_Constructor *c = (IDRIS2RC2_Constructor *)idris2rc2_alloc(
      sizeof(IDRIS2RC2_Constructor) + sizeof(IDRIS2RC2_Value *) * arity);
  c->header.tag = IDRIS2RC2_TAG_CONSTRUCTOR;
  c->arity = arity;
  c->tag = tag;
  c->name = NULL;
  return c;
}

IDRIS2RC2_Closure *idris2rc2_mkClosure(IDRIS2RC2_Value *(*fn)(), uint8_t arity, uint8_t filled) {
  // Always allocate room for the full `arity`, not just `filled` -- lets
  // idris2rc2_tailcallApplyClosure grow a unique closure in place
  // (args[filled] = arg; filled++) instead of reallocating on every
  // partial application. Overhead is at most (arity - filled) pointers,
  // and Idris2 functions rarely have many params.
  IDRIS2RC2_Closure *c = (IDRIS2RC2_Closure *)idris2rc2_alloc(sizeof(IDRIS2RC2_Closure) +
                                             sizeof(IDRIS2RC2_Value *) * arity);
  c->header.tag = IDRIS2RC2_TAG_CLOSURE;
  c->fn = fn;
  c->arity = arity;
  c->filled = filled;
  return c; // caller fills in args[]
}

IDRIS2RC2_Value *idris2rc2_mkDouble(double d) {
  IDRIS2RC2_Double *v = IDRIS2RC2_NEW(IDRIS2RC2_Double);
  v->header.tag = IDRIS2RC2_TAG_DOUBLE;
  v->v = d;
  return (IDRIS2RC2_Value *)v;
}

IDRIS2RC2_Value *idris2rc2_mkBits64(uint64_t i) {
  if (i < 100)
    return (IDRIS2RC2_Value *)&idris2rc2_smallBits64[i];
  IDRIS2RC2_Bits64 *v = IDRIS2RC2_NEW(IDRIS2RC2_Bits64);
  v->header.tag = IDRIS2RC2_TAG_BITS64;
  v->v = i;
  return (IDRIS2RC2_Value *)v;
}

IDRIS2RC2_Value *idris2rc2_mkInt64(int64_t i) {
  if (i >= 0 && i < 100)
    return (IDRIS2RC2_Value *)&idris2rc2_smallInt64[i];
  IDRIS2RC2_Int64 *v = IDRIS2RC2_NEW(IDRIS2RC2_Int64);
  v->header.tag = IDRIS2RC2_TAG_INT64;
  v->v = i;
  return (IDRIS2RC2_Value *)v;
}

IDRIS2RC2_Integer *idris2rc2_mkInteger(void) {
  IDRIS2RC2_Integer *v = IDRIS2RC2_NEW(IDRIS2RC2_Integer);
  v->header.tag = IDRIS2RC2_TAG_INTEGER;
  mpz_init(v->v);
  return v;
}

IDRIS2RC2_Value *idris2rc2_mkIntegerLiteral(char const *digits) {
  IDRIS2RC2_Integer *v = idris2rc2_mkInteger();
  mpz_set_str(v->v, digits, 10);
  return (IDRIS2RC2_Value *)v;
}

// A real copy (mpz_set), not aliasing -- src is a raw mpz_t an %export
// wrapper received straight from external C (Compiler.RC2.Emit's own
// emitExportWrapper), whose lifetime rc2 has no ownership over.
IDRIS2RC2_Integer *idris2rc2_mkIntegerFromMpz(mpz_t src) {
  IDRIS2RC2_Integer *v = idris2rc2_mkInteger();
  mpz_set(v->v, src);
  return v;
}

IDRIS2RC2_String *idris2rc2_mkEmptyString(size_t bufLen) {
  if (bufLen == 1)
    return (IDRIS2RC2_String *)&idris2rc2_emptyStringValue;
  IDRIS2RC2_String *v = IDRIS2RC2_NEW(IDRIS2RC2_String);
  v->header.tag = IDRIS2RC2_TAG_STRING;
  v->str = malloc(bufLen);
  IDRIS2RC2_VERIFY(v->str, "malloc failed");
  memset(v->str, 0, bufLen);
  return v;
}

IDRIS2RC2_String *idris2rc2_mkString(char const *s) {
  if (s[0] == '\0')
    return (IDRIS2RC2_String *)&idris2rc2_emptyStringValue;
  size_t l = strlen(s);
  IDRIS2RC2_String *v = IDRIS2RC2_NEW(IDRIS2RC2_String);
  v->header.tag = IDRIS2RC2_TAG_STRING;
  v->str = malloc(l + 1);
  IDRIS2RC2_VERIFY(v->str, "malloc failed");
  memcpy(v->str, s, l + 1);
  return v;
}

IDRIS2RC2_Pointer *idris2rc2_mkPointer(void *raw) {
  IDRIS2RC2_Pointer *p = IDRIS2RC2_NEW(IDRIS2RC2_Pointer);
  p->header.tag = IDRIS2RC2_TAG_POINTER;
  p->p = raw;
  return p;
}

IDRIS2RC2_GCPointer *idris2rc2_mkGCPointer(void *raw, IDRIS2RC2_Closure *onCollect) {
  IDRIS2RC2_GCPointer *p = IDRIS2RC2_NEW(IDRIS2RC2_GCPointer);
  p->header.tag = IDRIS2RC2_TAG_GCPOINTER;
  p->p = idris2rc2_mkPointer(raw);
  p->onCollect = onCollect;
  return p;
}

IDRIS2RC2_ThreadID *idris2rc2_mkThreadID(pthread_t tid) {
  IDRIS2RC2_ThreadID *t = IDRIS2RC2_NEW(IDRIS2RC2_ThreadID);
  t->header.tag = IDRIS2RC2_TAG_THREADID;
  t->tid = tid;
  return t;
}

IDRIS2RC2_Buffer *idris2rc2_mkBuffer(void *buf) {
  IDRIS2RC2_Buffer *b = IDRIS2RC2_NEW(IDRIS2RC2_Buffer);
  b->header.tag = IDRIS2RC2_TAG_BUFFER;
  b->buf = buf;
  return b;
}

IDRIS2RC2_Array *idris2rc2_mkArray(int length) {
  IDRIS2RC2_Array *a = IDRIS2RC2_NEW(IDRIS2RC2_Array);
  a->header.tag = IDRIS2RC2_TAG_ARRAY;
  atomic_flag_clear(&a->lock);
  a->capacity = length;
  a->items = (IDRIS2RC2_Value **)calloc(length, sizeof(IDRIS2RC2_Value *));
  IDRIS2RC2_VERIFY(length == 0 || a->items, "calloc failed");
  return a;
}

IDRIS2RC2_Value *idris2rc2_dup(IDRIS2RC2_Value *v) {
  if (v && !idris2rc2_is_unboxed(v) && v->header.refCount != IDRIS2RC2_REFCOUNT_MAX)
    atomic_fetch_add_explicit(&v->header.refCount, 1, memory_order_relaxed);
  return v;
}

IDRIS2RC2_Value *idris2rc2_dup_n(IDRIS2RC2_Value *v, int n) {
  if (v && !idris2rc2_is_unboxed(v) && v->header.refCount != IDRIS2RC2_REFCOUNT_MAX)
    atomic_fetch_add_explicit(&v->header.refCount, n, memory_order_relaxed);
  return v;
}

// Recursively drop `v`'s children (each of which may itself still be
// shared, so those go through the ordinary checked idris2rc2_drop) and
// then free `v` itself. Shared by idris2rc2_drop's refcount==1 case and by
// idris2rc2_free, which skips straight to this without checking/
// decrementing `v`'s own count first -- so it must only ever be called on
// a value the caller has *statically* proven has no other references.
static void idris2rc2_teardown(IDRIS2RC2_Value *v) {
  switch (v->header.tag) {
  case IDRIS2RC2_TAG_BITS32:
  case IDRIS2RC2_TAG_BITS64:
  case IDRIS2RC2_TAG_INT32:
  case IDRIS2RC2_TAG_INT64:
  case IDRIS2RC2_TAG_DOUBLE:
  case IDRIS2RC2_TAG_POINTER:
    break;
  case IDRIS2RC2_TAG_INTEGER:
    mpz_clear(((IDRIS2RC2_Integer *)v)->v);
    break;
  case IDRIS2RC2_TAG_STRING:
    free(((IDRIS2RC2_String *)v)->str);
    break;
  case IDRIS2RC2_TAG_CLOSURE: {
    IDRIS2RC2_Closure *c = (IDRIS2RC2_Closure *)v;
    for (int i = 0; i < c->filled; ++i)
      idris2rc2_drop(c->args[i]);
    break;
  }
  case IDRIS2RC2_TAG_CONSTRUCTOR: {
    IDRIS2RC2_Constructor *c = (IDRIS2RC2_Constructor *)v;
    for (int i = 0; i < c->arity; ++i)
      idris2rc2_drop(c->args[i]);
    break;
  }
  case IDRIS2RC2_TAG_IOREF:
    idris2rc2_drop(((IDRIS2RC2_IORef *)v)->v);
    break;
  case IDRIS2RC2_TAG_ARRAY: {
    IDRIS2RC2_Array *a = (IDRIS2RC2_Array *)v;
    for (int i = 0; i < a->capacity; ++i)
      idris2rc2_drop(a->items[i]);
    free(a->items);
    break;
  }
  case IDRIS2RC2_TAG_GCPOINTER: {
    // idris2rc2_applyClosure always fully consumes both of its own
    // arguments (see its own doc comment in runtime.c) -- and every
    // compiler-generated closure body disposes of an owned parameter
    // exactly once by the time it returns, whether by genuine use or
    // an inserted drop for an unused binding (RC.idr's
    // dropUnusedOwnedVars). So once onCollect has actually been
    // invoked, it has already consumed p->p itself -- an unconditional
    // drop here on top of that double-drops it. Only fall back to
    // dropping it ourselves when there's no onCollect closure to have
    // consumed it.
    IDRIS2RC2_GCPointer *p = (IDRIS2RC2_GCPointer *)v;
    if (p->onCollect) {
      IDRIS2RC2_Value *step1 = idris2rc2_applyClosure((IDRIS2RC2_Value *)p->onCollect, (IDRIS2RC2_Value *)p->p);
      IDRIS2RC2_Value *result = idris2rc2_applyClosure(step1, NULL);
      idris2rc2_drop(result);
    } else {
      idris2rc2_drop((IDRIS2RC2_Value *)p->p);
    }
    break;
  }
  case IDRIS2RC2_TAG_BUFFER:
    free(((IDRIS2RC2_Buffer *)v)->buf);
    break;
  case IDRIS2RC2_TAG_MUTEX:
    pthread_mutex_destroy(&((IDRIS2RC2_Mutex *)v)->mutex);
    break;
  case IDRIS2RC2_TAG_CONDITION:
    pthread_cond_destroy(&((IDRIS2RC2_Condition *)v)->cond);
    break;
  case IDRIS2RC2_TAG_SEMAPHORE:
    sem_destroy(&((IDRIS2RC2_Semaphore *)v)->sem);
    break;
  case IDRIS2RC2_TAG_BARRIER:
    pthread_barrier_destroy(&((IDRIS2RC2_Barrier *)v)->barrier);
    break;
  case IDRIS2RC2_TAG_JOINHANDLE: {
    IDRIS2RC2_JoinHandle *h = (IDRIS2RC2_JoinHandle *)v;
    if (!h->joined)
      pthread_detach(h->tid);
    break;
  }
  case IDRIS2RC2_TAG_THREADID:
    // idris2rc2_fork already pthread_detach()s before ever handing this
    // struct back -- unlike IDRIS2RC2_JOINHANDLE above, there's no join
    // decision left to make here, no pthread_t-destroying API to call.
    // Freeing this struct itself (below, unconditionally, after this
    // switch) is the whole of this tag's teardown.
    break;
  case IDRIS2RC2_TAG_CHANNEL: {
    IDRIS2RC2_Channel *c = (IDRIS2RC2_Channel *)v;
    idris2rc2_ChannelNode *node = c->head;
    while (node) {
      idris2rc2_ChannelNode *next = node->next;
      idris2rc2_drop(node->value);
      free(node);
      node = next;
    }
    pthread_mutex_destroy(&c->mutex);
    pthread_cond_destroy(&c->cond);
    break;
  }
  default:
    break;
  }
  free(v);
}

void idris2rc2_drop(IDRIS2RC2_Value *v) {
  if (!v || idris2rc2_is_unboxed(v))
    return;
  if (v->header.refCount == IDRIS2RC2_REFCOUNT_MAX)
    return; // immortal
  if (atomic_fetch_sub_explicit(&v->header.refCount, 1, memory_order_release) != 1)
    return;
  atomic_thread_fence(memory_order_acquire);
  idris2rc2_teardown(v);
}

void idris2rc2_free(IDRIS2RC2_Value *v) {
  // No refcount check, no decrement: the caller (rc2's generated code,
  // via the RFree IR primitive) has already proven statically that `v` is
  // a brand-new allocation with no other references -- see RC.idr's
  // `freeableShape`. Still a no-op for NULL/unboxed, both of which are
  // never real heap allocations to begin with.
  if (!v || idris2rc2_is_unboxed(v))
    return;
  IDRIS2RC2_VERIFY(v->header.refCount == 1,
                   "idris2rc2_free called on a shared value (refCount=%d)",
                   (int)v->header.refCount);
  idris2rc2_teardown(v);
}

#define IDRIS2RC2_MK10(t, n)                                                       \
  {IDRIS2RC2_STOCKVAL(t), (n + 0)}, {IDRIS2RC2_STOCKVAL(t), (n + 1)},                    \
      {IDRIS2RC2_STOCKVAL(t), (n + 2)}, {IDRIS2RC2_STOCKVAL(t), (n + 3)},                \
      {IDRIS2RC2_STOCKVAL(t), (n + 4)}, {IDRIS2RC2_STOCKVAL(t), (n + 5)},                \
      {IDRIS2RC2_STOCKVAL(t), (n + 6)}, {IDRIS2RC2_STOCKVAL(t), (n + 7)},                \
      {IDRIS2RC2_STOCKVAL(t), (n + 8)}, { IDRIS2RC2_STOCKVAL(t), (n + 9) }

IDRIS2RC2_Int64 const idris2rc2_smallInt64[100] = {
    IDRIS2RC2_MK10(IDRIS2RC2_TAG_INT64, 0),  IDRIS2RC2_MK10(IDRIS2RC2_TAG_INT64, 10),
    IDRIS2RC2_MK10(IDRIS2RC2_TAG_INT64, 20), IDRIS2RC2_MK10(IDRIS2RC2_TAG_INT64, 30),
    IDRIS2RC2_MK10(IDRIS2RC2_TAG_INT64, 40), IDRIS2RC2_MK10(IDRIS2RC2_TAG_INT64, 50),
    IDRIS2RC2_MK10(IDRIS2RC2_TAG_INT64, 60), IDRIS2RC2_MK10(IDRIS2RC2_TAG_INT64, 70),
    IDRIS2RC2_MK10(IDRIS2RC2_TAG_INT64, 80), IDRIS2RC2_MK10(IDRIS2RC2_TAG_INT64, 90)};

IDRIS2RC2_Bits64 const idris2rc2_smallBits64[100] = {
    IDRIS2RC2_MK10(IDRIS2RC2_TAG_BITS64, 0),  IDRIS2RC2_MK10(IDRIS2RC2_TAG_BITS64, 10),
    IDRIS2RC2_MK10(IDRIS2RC2_TAG_BITS64, 20), IDRIS2RC2_MK10(IDRIS2RC2_TAG_BITS64, 30),
    IDRIS2RC2_MK10(IDRIS2RC2_TAG_BITS64, 40), IDRIS2RC2_MK10(IDRIS2RC2_TAG_BITS64, 50),
    IDRIS2RC2_MK10(IDRIS2RC2_TAG_BITS64, 60), IDRIS2RC2_MK10(IDRIS2RC2_TAG_BITS64, 70),
    IDRIS2RC2_MK10(IDRIS2RC2_TAG_BITS64, 80), IDRIS2RC2_MK10(IDRIS2RC2_TAG_BITS64, 90)};

IDRIS2RC2_String const idris2rc2_emptyStringValue = {IDRIS2RC2_STOCKVAL(IDRIS2RC2_TAG_STRING), ""};

IDRIS2RC2_Integer idris2rc2_smallInteger[100];

static pthread_once_t idris2rc2_smallIntegerOnce = PTHREAD_ONCE_INIT;

static void idris2rc2_initSmallInteger(void) {
  for (int i = 0; i < 100; ++i) {
    idris2rc2_smallInteger[i].header.refCount = IDRIS2RC2_REFCOUNT_MAX;
    idris2rc2_smallInteger[i].header.tag = IDRIS2RC2_TAG_INTEGER;
    idris2rc2_smallInteger[i].header.reserved = 0;
    mpz_init(idris2rc2_smallInteger[i].v);
    mpz_set_si(idris2rc2_smallInteger[i].v, i);
  }
}

IDRIS2RC2_Value *idris2rc2_getSmallInteger(int n) {
  IDRIS2RC2_VERIFY(n >= 0 && n < 100, "out of range: %d", n);
  pthread_once(&idris2rc2_smallIntegerOnce, idris2rc2_initSmallInteger);
  return (IDRIS2RC2_Value *)&idris2rc2_smallInteger[n];
}
