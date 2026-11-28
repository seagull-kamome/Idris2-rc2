#include "idris2rc2_memory.h"
#include "idris2rc2_pool.h"
#include "idris2rc2_rt.h"
#include "idris2rc2_util.h"

#include <pthread.h>

bool idris2rc2_threaded = false;

void idris2rc2_enableMultiThreading(void) {
  // Only the first call may write: later ones can run while other threads
  // read the flag.
  if (!idris2rc2_threaded)
    idris2rc2_threaded = true;
}

int idris2rc2_isMultiThreaded(void) {
  return idris2rc2_threaded;
}

static inline IDRIS2RC2_Value *idris2rc2_allocWithHeader(size_t size) {
  // Plain malloc, not aligned_alloc: malloc already aligns to 16, which
  // leaves the tag bits free, and aligned_alloc takes a slow path in some
  // allocators (TODO.md, "a small-object allocator in the runtime").
  IDRIS2RC2_Value *v = (IDRIS2RC2_Value *)malloc(size);
  IDRIS2RC2_VERIFY(v && !idris2rc2_is_unboxed(v), "allocation failed");
  v->header.rc = 1;
  v->header.tag = IDRIS2RC2_TAG_NONE;
  v->header.reserved = 0;
  return v;
}

IDRIS2RC2_Value *idris2rc2_alloc(size_t size) {
  return idris2rc2_allocWithHeader(size);
}

IDRIS2RC2_Value *idris2rc2_cellAlloc(size_t size) {
  int k = idris2rc2_poolClass(size);
  if (__builtin_expect(k < 0 || !idris2rc2_poolOn, 0))
    return idris2rc2_allocWithHeader(size);
  IDRIS2RC2_Value *v = (IDRIS2RC2_Value *)idris2rc2_poolAlloc(k);
  v->header.rc = 1;
  v->header.tag = IDRIS2RC2_TAG_NONE;
  v->header.reserved = IDRIS2RC2_HDR_POOLED;
  return v;
}

void idris2rc2_cellFree(void *cell) {
  if (!cell) return;
  idris2rc2_cellFreeInline(cell);
}

IDRIS2RC2_Value *idris2rc2_wrapJust(IDRIS2RC2_Value *val) {
  IDRIS2RC2_Constructor *just = idris2rc2_newConstructor(1, 1);
  just->args[0] = val;
  return (IDRIS2RC2_Value *)just;
}

IDRIS2RC2_Value *idris2rc2_mkDouble(double d) {
  IDRIS2RC2_Double *v = IDRIS2RC2_NEW_CELL(IDRIS2RC2_Double);
  v->header.tag = IDRIS2RC2_TAG_DOUBLE;
  v->v = d;
  return (IDRIS2RC2_Value *)v;
}

IDRIS2RC2_Value *idris2rc2_mkBits64(uint64_t i) {
  if (i < IDRIS2RC2_IMM_U64_LIMIT)
    return IDRIS2RC2_IMM_BITS64(i);
  IDRIS2RC2_Bits64 *v = IDRIS2RC2_NEW_CELL(IDRIS2RC2_Bits64);
  v->header.tag = IDRIS2RC2_TAG_BITS64;
  v->v = i;
  return (IDRIS2RC2_Value *)v;
}

IDRIS2RC2_Value *idris2rc2_mkInt64Boxed(int64_t i) {
  IDRIS2RC2_Int64 *v = IDRIS2RC2_NEW_CELL(IDRIS2RC2_Int64);
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

IDRIS2RC2_Value *idris2rc2_integerNormalize(IDRIS2RC2_Integer *r) {
  int size = r->v->_mp_size;
  if (size == 0) {
    idris2rc2_drop((IDRIS2RC2_Value *)r);
    return IDRIS2RC2_IMM_INT64(0);
  }
  if (size != 1 && size != -1)
    return (IDRIS2RC2_Value *)r;
  uint64_t mag = r->v->_mp_d[0];
  if (size > 0 ? mag >= (uint64_t)IDRIS2RC2_IMM_I64_LIMIT : mag > (uint64_t)IDRIS2RC2_IMM_I64_LIMIT)
    return (IDRIS2RC2_Value *)r;
  idris2rc2_drop((IDRIS2RC2_Value *)r);
  return IDRIS2RC2_IMM_INT64(size > 0 ? (int64_t)mag : -(int64_t)mag);
}

IDRIS2RC2_Value *idris2rc2_mkIntegerBoxedI64(int64_t n) {
  IDRIS2RC2_Integer *v = idris2rc2_mkInteger();
  mpz_set_si(v->v, n);
  return (IDRIS2RC2_Value *)v;
}

IDRIS2RC2_Value *idris2rc2_mkIntegerBoxedU64(uint64_t n) {
  IDRIS2RC2_Integer *v = idris2rc2_mkInteger();
  mpz_set_ui(v->v, n);
  return (IDRIS2RC2_Value *)v;
}

IDRIS2RC2_Value *idris2rc2_mkIntegerLiteral(char const *digits) {
  IDRIS2RC2_Integer *v = idris2rc2_mkInteger();
  mpz_set_str(v->v, digits, 10);
  return idris2rc2_integerNormalize(v);
}

// A real copy (mpz_set), not aliasing -- src is a raw mpz_t an %export
// wrapper received straight from external C (Compiler.RC2.Emit's own
// emitExportWrapper), whose lifetime rc2 has no ownership over.
IDRIS2RC2_Value *idris2rc2_mkIntegerFromMpz(mpz_srcptr src) {
  IDRIS2RC2_Integer *v = idris2rc2_mkInteger();
  mpz_set(v->v, src);
  return idris2rc2_integerNormalize(v);
}

// A String and its `len + 1` content bytes in one allocation
// (rc2/doc/constructor-layout.md, "Strings"). The caller fills the content.
static IDRIS2RC2_String *idris2rc2_allocString(size_t len) {
  uint32_t const checked = idris2rc2_checkedStrLen(len);
  IDRIS2RC2_String *v = (IDRIS2RC2_String *)idris2rc2_alloc(sizeof(IDRIS2RC2_String) + len + 1);
  v->header.tag = IDRIS2RC2_TAG_STRING;
  v->header.reserved = IDRIS2RC2_HDR_FLAG;
  v->len = checked;
  v->str = (char *)(v + 1);
  return v;
}

IDRIS2RC2_String *idris2rc2_mkEmptyString(size_t bufLen) {
  if (bufLen == 1)
    return (IDRIS2RC2_String *)&idris2rc2_emptyStringValue;
  IDRIS2RC2_String *v = idris2rc2_allocString(bufLen - 1);
  // Only the terminator: every caller writes the bufLen - 1 bytes before it.
  v->str[bufLen - 1] = '\0';
  return v;
}

IDRIS2RC2_String *idris2rc2_mkString(char const *s) {
  if (s[0] == '\0')
    return (IDRIS2RC2_String *)&idris2rc2_emptyStringValue;
  return idris2rc2_mkStringLen(s, strlen(s));
}

IDRIS2RC2_String *idris2rc2_mkStringLen(char const *s, size_t len) {
  if (len == 0)
    return (IDRIS2RC2_String *)&idris2rc2_emptyStringValue;
  IDRIS2RC2_String *v = idris2rc2_allocString(len);
  memcpy(v->str, s, len);
  v->str[len] = '\0';
  return v;
}

IDRIS2RC2_GCPointer *idris2rc2_mkGCPointer(void *raw, IDRIS2RC2_Closure *onCollect) {
  IDRIS2RC2_GCPointer *p = IDRIS2RC2_NEW_CELL(IDRIS2RC2_GCPointer);
  p->header.tag = IDRIS2RC2_TAG_GCPOINTER;
  p->p = idris2rc2_mkPtr(raw);
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

// idris2rc2_dup/idris2rc2_dup_n/idris2rc2_drop's own hot paths are
// `static inline` in memory.h, not defined here -- see that header's
// own comment for why. Only idris2rc2_teardown (below, the cold path
// those inline functions call into once a value's last reference is
// actually dropped) and idris2rc2_free (which always skips straight to
// teardown) live in this translation unit.

// Whether `v` can hold further heap values. No dying child of such a kind
// is torn down by recursion, so freeing a value takes no C stack
// proportional to its size, whatever its shape (a list of pairs, a
// `SnocList` of records, a list of lists, a chain of IORefs):
// - the last field with children of a constructor or closure, and the
//   value of a lazy cell or an IORef, is looped on: the cell is freed and
//   the walk goes on from it, with no `next` to carry (a register gcc kept
//   resetting on every call);
// - an earlier field with children hands the rest of the walk to
//   idris2rc2_teardownWaiting, which frees a dead cell under a field where
//   it stands and, where it cannot, makes a cell wait on a chain that
//   costs no memory of its own: a released field links the cell before
//   it, and the cell's dead reference count holds the field to go on
//   from (Koka's `kk_block_drop_free_recx` keeps its parents the same way).
// A dying child of any other kind is torn down by a call of its own. That
// call does not come back here for a string, a number or a buffer, but
// does for an array's items, a GCPointer's value (or the finalizer run on
// it) and a channel's queued values, which it drops one by one: the C
// stack then grows with how deeply arrays, GCPointers and channels nest
// inside each other, not with the size of what they hold.
// Not a general worklist: that cost 5-7% more instructions on a
// free-heavy benchmark, since every teardown paid to set it up; the
// waiting chain lives out of line for the same reason, so the common path
// keeps a short shape and few registers.
#define IDRIS2RC2_TAGS_WITH_CHILDREN \
  ((1ull << IDRIS2RC2_TAG_CONSTRUCTOR) | (1ull << IDRIS2RC2_TAG_CLOSURE) | (1ull << IDRIS2RC2_TAG_LAZY) | \
   (1ull << IDRIS2RC2_TAG_IOREF))
_Static_assert(IDRIS2RC2_TAG_LAZY < 64, "every tag is a bit of a 64-bit mask");
static inline int idris2rc2_hasChildren(IDRIS2RC2_Value *v) {
  return (IDRIS2RC2_TAGS_WITH_CHILDREN >> v->header.tag) & 1;
}

// Whether dropping `v` released its last reference, like idris2rc2_drop
// minus the teardown itself.
static inline int idris2rc2_releaseLast(IDRIS2RC2_Value *v) {
  return v && !idris2rc2_is_unboxed(v) && idris2rc2_rc_release(&v->header);
}

static void idris2rc2_teardownWaiting(IDRIS2RC2_Value *v, int k, IDRIS2RC2_Value *c);

// Drop `v`'s children (each of which may itself still be shared, so
// each goes through the same checked decrement as idris2rc2_drop) and
// then free `v` itself. Shared by idris2rc2_drop's refcount==1 case and by
// idris2rc2_free, which skips straight to this without checking/
// decrementing `v`'s own count first -- so it must only ever be called on
// a value the caller has *statically* proven has no other references.
void idris2rc2_teardown(IDRIS2RC2_Value *v) {
  IDRIS2RC2_Value **args;
  int n;
again:
  // The commonest tag by far, tested before the switch's indirect jump.
  // Constructors and closures share the one loop over the fields below. No
  // __builtin_expect: with it gcc took the other tags for cold and stopped
  // inlining idris2rc2_releaseLast and idris2rc2_drop (5-6% more cycles on
  // the list benchmarks, 2026-11-19).
  if (v->header.tag == IDRIS2RC2_TAG_CONSTRUCTOR) {
    args = ((IDRIS2RC2_Constructor *)v)->args;
    n = ((IDRIS2RC2_Constructor *)v)->arity;
    goto fields;
  }
  switch (v->header.tag) {
  case IDRIS2RC2_TAG_BITS32:
  case IDRIS2RC2_TAG_BITS64:
  case IDRIS2RC2_TAG_INT32:
  case IDRIS2RC2_TAG_INT64:
  case IDRIS2RC2_TAG_DOUBLE:
    break;
  case IDRIS2RC2_TAG_INTEGER:
    mpz_clear(((IDRIS2RC2_Integer *)v)->v);
    break;
  case IDRIS2RC2_TAG_STRING:
    if (!(v->header.reserved & IDRIS2RC2_HDR_FLAG))
      free(((IDRIS2RC2_String *)v)->str);
    break;
  case IDRIS2RC2_TAG_CLOSURE:
    args = ((IDRIS2RC2_Closure *)v)->args;
    n = ((IDRIS2RC2_Closure *)v)->filled;
  fields:
    for (int i = 0; i < n - 1; ++i)
      if (idris2rc2_releaseLast(args[i])) {
        if (idris2rc2_hasChildren(args[i])) {
          idris2rc2_teardownWaiting(v, i, args[i]); // the rest of the walk
          return;
        }
        idris2rc2_teardown(args[i]); // nothing this walk follows (see IDRIS2RC2_TAGS_WITH_CHILDREN)
      }
    if (n > 0 && idris2rc2_releaseLast(args[n - 1])) {
      IDRIS2RC2_Value *x = args[n - 1];
      if (idris2rc2_hasChildren(x)) {
        idris2rc2_cellFreeInline(v); // the last field is looped on
        v = x;
        goto again;
      }
      idris2rc2_teardown(x);
    }
    break;
  case IDRIS2RC2_TAG_IOREF: {
    // Deferred like a lazy cell's value: a chain of IORefs loops.
    IDRIS2RC2_Value *x = ((IDRIS2RC2_IORef *)v)->v;
    if (idris2rc2_releaseLast(x)) {
      if (idris2rc2_hasChildren(x)) {
        idris2rc2_cellFreeInline(v);
        v = x;
        goto again;
      }
      idris2rc2_teardown(x);
    }
    break;
  }
  case IDRIS2RC2_TAG_LAZY: {
    // Deferred like a constructor field, so freeing a long forced stream
    // (cons -> cell -> cons -> ...) loops instead of recursing.
    IDRIS2RC2_Value *x = atomic_load_explicit(&((IDRIS2RC2_IORef *)v)->av, memory_order_acquire);
    if (idris2rc2_releaseLast(x)) {
      if (idris2rc2_hasChildren(x)) {
        idris2rc2_cellFreeInline(v);
        v = x;
        goto again;
      }
      idris2rc2_teardown(x);
    }
    break;
  }
  case IDRIS2RC2_TAG_ARRAY: {
    IDRIS2RC2_Array *a = (IDRIS2RC2_Array *)v;
    for (int i = 0; i < a->capacity; ++i)
      idris2rc2_drop(a->items[i]);
    free(a->items);
    break;
  }
  case IDRIS2RC2_TAG_GCPOINTER: {
    // idris2rc2_applyClosure always fully consumes both of its own
    // arguments (see its own doc comment in idris2rc2_rt.c) -- and every
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
  idris2rc2_cellFreeInline(v);
}

// The fields of a constructor or closure, and how many.
static inline IDRIS2RC2_Value **idris2rc2_fieldsOf(IDRIS2RC2_Value *v, int *n) {
  if (v->header.tag == IDRIS2RC2_TAG_CONSTRUCTOR) {
    *n = ((IDRIS2RC2_Constructor *)v)->arity;
    return ((IDRIS2RC2_Constructor *)v)->args;
  }
  *n = ((IDRIS2RC2_Closure *)v)->filled;
  return ((IDRIS2RC2_Closure *)v)->args;
}

// Whether `v` is a value whose last reference was released already.
// Relies on no live value having a count of 0: a static or stack-built
// value is immortal (IDRIS2RC2_REFCOUNT_MAX), a fresh cell starts at 1.
// idris2rc2_teardownWaiting tells a kept cell (its first field dead) from
// one not yet entered (its first field still held) by this alone, so a
// value that lived at count 0 (were borrowing ever to make one) would make
// it take a cell not yet entered for a kept one and free that live
// first field. Such a value must not reach it.
static inline int idris2rc2_isDead(IDRIS2RC2_Value *v) {
  return v && !idris2rc2_is_unboxed(v) && atomic_load_explicit(&v->header.refCount, memory_order_relaxed) == 0;
}

// The rest of a teardown once field `k` of the constructor or closure `v`
// (already released, `c`) is a dead value with children and is not the
// last. No C frame per level, and no memory but the dead cells' own (see
// IDRIS2RC2_TAGS_WITH_CHILDREN):
// - a dead cell under a field of `v` has its own fields released where it
//   stands, in a loop inside `v`'s, and is freed there; a dead last field
//   with children takes its place, so a chain through last fields is a
//   loop too;
// - when its first field is dead with children, the cell is kept (`deep`)
//   and entered after `v`, at that field: a chain through first fields;
// - a second such cell is entered at once, and `v` waits; so does a cell
//   with such a field between its first and its last. The waiting cells
//   form a chain (`parent`), each linked through the field before the one
//   it goes on from, with that field's number in its dead reference count
//   (arity and `filled` fit its 16 bits).
static __attribute__((noinline)) void idris2rc2_teardownWaiting(IDRIS2RC2_Value *v, int k, IDRIS2RC2_Value *c) {
  IDRIS2RC2_Value *parent = NULL;
  IDRIS2RC2_Value *deep = NULL;
  IDRIS2RC2_Value **args, **cargs;
  int n, i = k, cn;
  args = idris2rc2_fieldsOf(v, &n);
  goto child;
fields:
  for (; i < n; ++i) {
    c = args[i];
    if (!idris2rc2_releaseLast(c))
      continue;
    if (__builtin_expect(!idris2rc2_hasChildren(c), 0)) {
      idris2rc2_teardown(c); // nothing this walk follows (see IDRIS2RC2_TAGS_WITH_CHILDREN)
      continue;
    }
  child:
    // `c`, under field i of `v`, is dead and can hold children
    if (c->header.tag == IDRIS2RC2_TAG_CONSTRUCTOR) {
      cargs = ((IDRIS2RC2_Constructor *)c)->args;
      cn = ((IDRIS2RC2_Constructor *)c)->arity;
    } else if (c->header.tag == IDRIS2RC2_TAG_CLOSURE) {
      cargs = ((IDRIS2RC2_Closure *)c)->args;
      cn = ((IDRIS2RC2_Closure *)c)->filled;
    } else {
      // a lazy cell or an IORef: its value is its last field
      IDRIS2RC2_Value *d = c->header.tag == IDRIS2RC2_TAG_LAZY
        ? atomic_load_explicit(&((IDRIS2RC2_IORef *)c)->av, memory_order_acquire)
        : ((IDRIS2RC2_IORef *)c)->v;
      if (idris2rc2_releaseLast(d)) {
        if (idris2rc2_hasChildren(d)) {
          idris2rc2_cellFreeInline(c);
          c = d;
          goto child;
        }
        idris2rc2_teardown(d);
      }
      cn = 0;
    }
    for (int j = 0; j < cn; ++j) {
      IDRIS2RC2_Value *d = cargs[j];
      if (idris2rc2_releaseLast(d)) {
        if (__builtin_expect(idris2rc2_hasChildren(d), 1)) {
          if (j == cn - 1) {
            // the last field: `c` is done with, and `d` takes its place
            idris2rc2_cellFreeInline(c);
            c = d;
            goto child;
          }
          if (j == 0) {
            // the first: `c` is kept for after `v`, or entered now
            if (__builtin_expect(deep != NULL, 0))
              goto wait;
            deep = c;
          } else {
            // between: `c` waits to go on from field j
            cargs[j - 1] = parent;
            c->header.rc = (uint16_t)j;
            parent = c;
          }
          goto walked;
        }
        idris2rc2_teardown(d); // nothing this walk follows (see IDRIS2RC2_TAGS_WITH_CHILDREN)
      }
    }
    idris2rc2_cellFreeInline(c);
  walked:;
  }
  idris2rc2_cellFreeInline(v);
  if (deep) {
    // the cell kept is entered at its first field, dead already
    v = deep;
    deep = NULL;
  enter:
    args = idris2rc2_fieldsOf(v, &n);
    i = 0;
    c = args[0];
    goto child;
  }
  if (!parent)
    return;
  // Back to the innermost waiting cell, at the field it is to go on from.
  // That field is dead already: the one it waited at, still whole, or the
  // cell that was kept when it began to wait, whose first field is dead too
  // (told apart by idris2rc2_isDead, whose comment says what that needs).
  v = parent;
  i = v->header.rc;
  args = idris2rc2_fieldsOf(v, &n);
  parent = args[i - 1];
  c = args[i];
  if (c->header.tag == IDRIS2RC2_TAG_CONSTRUCTOR || c->header.tag == IDRIS2RC2_TAG_CLOSURE) {
    cargs = idris2rc2_fieldsOf(c, &cn);
    if (__builtin_expect(cn > 0 && idris2rc2_isDead(cargs[0]), 0)) {
      deep = c;
      ++i;
      goto fields;
    }
  }
  goto child;
wait:
  // Two cells are in hand whose first field is dead: the one kept and `c`.
  // `c` is entered now and `v` waits: the kept one becomes field i of `v`,
  // where `v` goes on from, and field i - 1 links the cell waiting before
  // `v`. Both fields are free: the kept one was met under a field before i,
  // and `c` under field i.
  args[i] = deep;
  args[i - 1] = parent;
  v->header.rc = (uint16_t)i;
  parent = v;
  deep = NULL;
  v = c;
  goto enter;
}

// The flag is read again for each drop: a teardown can run a finalizer that
// forks, and the drops after it must then be atomic. A dup runs nothing.
IDRIS2RC2_RC_CC void idris2rc2_drop3(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b, IDRIS2RC2_Value *c) {
  if (__builtin_expect(!idris2rc2_threaded, 1)) idris2rc2_dropPlain(a); else idris2rc2_drop(a);
  if (__builtin_expect(!idris2rc2_threaded, 1)) idris2rc2_dropPlain(b); else idris2rc2_drop(b);
  if (__builtin_expect(!idris2rc2_threaded, 1)) idris2rc2_dropPlain(c); else idris2rc2_drop(c);
}
IDRIS2RC2_RC_CC void idris2rc2_drop4(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b, IDRIS2RC2_Value *c, IDRIS2RC2_Value *d) {
  if (__builtin_expect(!idris2rc2_threaded, 1)) idris2rc2_dropPlain(a); else idris2rc2_drop(a);
  if (__builtin_expect(!idris2rc2_threaded, 1)) idris2rc2_dropPlain(b); else idris2rc2_drop(b);
  if (__builtin_expect(!idris2rc2_threaded, 1)) idris2rc2_dropPlain(c); else idris2rc2_drop(c);
  if (__builtin_expect(!idris2rc2_threaded, 1)) idris2rc2_dropPlain(d); else idris2rc2_drop(d);
}
IDRIS2RC2_RC_CC void idris2rc2_drop5(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b, IDRIS2RC2_Value *c, IDRIS2RC2_Value *d, IDRIS2RC2_Value *e) {
  if (__builtin_expect(!idris2rc2_threaded, 1)) idris2rc2_dropPlain(a); else idris2rc2_drop(a);
  if (__builtin_expect(!idris2rc2_threaded, 1)) idris2rc2_dropPlain(b); else idris2rc2_drop(b);
  if (__builtin_expect(!idris2rc2_threaded, 1)) idris2rc2_dropPlain(c); else idris2rc2_drop(c);
  if (__builtin_expect(!idris2rc2_threaded, 1)) idris2rc2_dropPlain(d); else idris2rc2_drop(d);
  if (__builtin_expect(!idris2rc2_threaded, 1)) idris2rc2_dropPlain(e); else idris2rc2_drop(e);
}
IDRIS2RC2_RC_CC void idris2rc2_drop6(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b, IDRIS2RC2_Value *c, IDRIS2RC2_Value *d, IDRIS2RC2_Value *e, IDRIS2RC2_Value *f) {
  if (__builtin_expect(!idris2rc2_threaded, 1)) idris2rc2_dropPlain(a); else idris2rc2_drop(a);
  if (__builtin_expect(!idris2rc2_threaded, 1)) idris2rc2_dropPlain(b); else idris2rc2_drop(b);
  if (__builtin_expect(!idris2rc2_threaded, 1)) idris2rc2_dropPlain(c); else idris2rc2_drop(c);
  if (__builtin_expect(!idris2rc2_threaded, 1)) idris2rc2_dropPlain(d); else idris2rc2_drop(d);
  if (__builtin_expect(!idris2rc2_threaded, 1)) idris2rc2_dropPlain(e); else idris2rc2_drop(e);
  if (__builtin_expect(!idris2rc2_threaded, 1)) idris2rc2_dropPlain(f); else idris2rc2_drop(f);
}

IDRIS2RC2_RC_CC void idris2rc2_dup3(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b, IDRIS2RC2_Value *c) {
  if (__builtin_expect(!idris2rc2_threaded, 1)) { idris2rc2_dupPlain(a); idris2rc2_dupPlain(b); idris2rc2_dupPlain(c); }
  else { idris2rc2_dup(a); idris2rc2_dup(b); idris2rc2_dup(c); }
}
IDRIS2RC2_RC_CC void idris2rc2_dup4(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b, IDRIS2RC2_Value *c, IDRIS2RC2_Value *d) {
  if (__builtin_expect(!idris2rc2_threaded, 1)) { idris2rc2_dupPlain(a); idris2rc2_dupPlain(b); idris2rc2_dupPlain(c); idris2rc2_dupPlain(d); }
  else { idris2rc2_dup(a); idris2rc2_dup(b); idris2rc2_dup(c); idris2rc2_dup(d); }
}
IDRIS2RC2_RC_CC void idris2rc2_dup5(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b, IDRIS2RC2_Value *c, IDRIS2RC2_Value *d, IDRIS2RC2_Value *e) {
  if (__builtin_expect(!idris2rc2_threaded, 1)) { idris2rc2_dupPlain(a); idris2rc2_dupPlain(b); idris2rc2_dupPlain(c); idris2rc2_dupPlain(d); idris2rc2_dupPlain(e); }
  else { idris2rc2_dup(a); idris2rc2_dup(b); idris2rc2_dup(c); idris2rc2_dup(d); idris2rc2_dup(e); }
}
IDRIS2RC2_RC_CC void idris2rc2_dup6(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b, IDRIS2RC2_Value *c, IDRIS2RC2_Value *d, IDRIS2RC2_Value *e, IDRIS2RC2_Value *f) {
  if (__builtin_expect(!idris2rc2_threaded, 1)) { idris2rc2_dupPlain(a); idris2rc2_dupPlain(b); idris2rc2_dupPlain(c); idris2rc2_dupPlain(d); idris2rc2_dupPlain(e); idris2rc2_dupPlain(f); }
  else { idris2rc2_dup(a); idris2rc2_dup(b); idris2rc2_dup(c); idris2rc2_dup(d); idris2rc2_dup(e); idris2rc2_dup(f); }
}

void idris2rc2_free(IDRIS2RC2_Value *v) {
  // No refcount check, no decrement: the caller (rc2's generated code,
  // via the RFree IR primitive) has already proven statically that `v` is
  // a brand-new allocation with no other references -- see RC.idr's
  // `freeableShape`. Still a no-op for NULL/unboxed, both of which are
  // never real heap allocations to begin with.
  if (!v || idris2rc2_is_unboxed(v))
    return;
  IDRIS2RC2_VERIFY(v->header.rc == 1,
                   "idris2rc2_free called on a shared value (refCount=%d)",
                   (int)v->header.rc);
  idris2rc2_teardown(v);
}

IDRIS2RC2_String const idris2rc2_emptyStringValue = {IDRIS2RC2_STOCKVAL(IDRIS2RC2_TAG_STRING), 0, ""};

