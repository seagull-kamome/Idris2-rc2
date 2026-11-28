#include "idris2rc2_ioprims.h"

#include <errno.h>
#include <limits.h>

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <unistd.h>

#include "idris2rc2_memory.h"
#include "idris2rc2_rt.h"
#include "idris2rc2_util.h"

IDRIS2RC2_Value *idris2rc2_Data_IORef_prim__newIORef(IDRIS2RC2_Value *erased,
						     IDRIS2RC2_Value *v,
						     IDRIS2RC2_Value *world) {
  IDRIS2RC2_IORef *r = IDRIS2RC2_NEW_CELL(IDRIS2RC2_IORef);
  r->header.tag = IDRIS2RC2_TAG_IOREF;
  atomic_flag_clear(&r->lock);
  r->v = idris2rc2_dup(v);
  return (IDRIS2RC2_Value *)r;
}

// The threaded halves of readIORef and writeIORef (ioprims.h): the lock
// keeps a reader's load+dup apart from a writer's swap and drop
// (idris2rc2_util.h's idris2rc2_spin_lock).
IDRIS2RC2_Value *idris2rc2_ioref_readLocked(IDRIS2RC2_IORef *r) {
  idris2rc2_spin_lock(&r->lock);
  IDRIS2RC2_Value *result = idris2rc2_dup(r->v);
  idris2rc2_spin_unlock(&r->lock);
  return result;
}

void idris2rc2_ioref_writeLocked(IDRIS2RC2_IORef *r, IDRIS2RC2_Value *newValue) {
  idris2rc2_dup(newValue);
  idris2rc2_spin_lock(&r->lock);
  IDRIS2RC2_Value *old = r->v;
  r->v = newValue;
  idris2rc2_spin_unlock(&r->lock);
  idris2rc2_drop(old);
}

// Atomic compare-and-swap against an IORef's own current value,
// compared by reference identity (the same tagged-pointer bit pattern
// `expected` itself is, never `Eq`) -- guarded by the same
// idris2rc2_spin_lock every other IDRIS2RC2_IORef mutator already
// uses (idris2rc2_util.h's own doc comment on why a lock-free hardware
// CAS on `r->v` alone would NOT be safe here: it would let this
// operation race a concurrent reader's own load+dup sequence, the
// exact use-after-free the spinlock exists to rule out -- so this
// reuses it rather than introducing a second, incompatible
// synchronization discipline for the same field).
//
// Returns Nothing on success (the swap happened -- Compiler.RC2.Emit's
// own RCon/RConCase represent that as a bare NULL, never a real
// allocation, so the fast/common path costs nothing extra) or
// `Just <the value actually there>` on failure (idris2rc2_wrapJust,
// memory.h) -- one allocation only on the losing path of a retry
// loop, and the caller gets the witness value for free instead of a
// separate readIORef call (which would itself race a concurrent
// writer between the two calls).
IDRIS2RC2_Value *idris2rc2_ioref_cas(IDRIS2RC2_Value *erased,
				     IDRIS2RC2_Value *ioref,
				     IDRIS2RC2_Value *expected,
				     IDRIS2RC2_Value *desired) {
  IDRIS2RC2_IORef *r = (IDRIS2RC2_IORef *)ioref;
  idris2rc2_spin_lock(&r->lock);
  if (r->v == expected) {
    idris2rc2_dup(desired);
    IDRIS2RC2_Value *old = r->v;
    r->v = desired;
    idris2rc2_spin_unlock(&r->lock);
    idris2rc2_drop(old);
    return NULL;
  }
  IDRIS2RC2_Value *current = idris2rc2_dup(r->v);
  idris2rc2_spin_unlock(&r->lock);
  return idris2rc2_wrapJust(current);
}

IDRIS2RC2_Value *idris2rc2_Data_IOArray_Prims_prim__newArray(
    IDRIS2RC2_Value *erased, IDRIS2RC2_Value *length, IDRIS2RC2_Value *v,
    IDRIS2RC2_Value *world) {
  // The array keeps its capacity in an `int`: a length that does not fit would
  // wrap to a short array that the caller's own bounds check does not know about.
  int64_t asked = (int64_t)idris2rc2_extractInt(length);
  IDRIS2RC2_VERIFY(asked >= 0 && asked <= INT_MAX, "newArray: length %lld is out of range", (long long)asked);
  int len = (int)asked;
  IDRIS2RC2_Array *a = idris2rc2_mkArray(len);
  for (int i = 0; i < len; i++) a->items[i] = idris2rc2_dup(v);
  return (IDRIS2RC2_Value *)a;
}

IDRIS2RC2_Value *idris2rc2_Data_IOArray_Prims_prim__arrayGet(
    IDRIS2RC2_Value *erased, IDRIS2RC2_Value *array, IDRIS2RC2_Value *index,
    IDRIS2RC2_Value *world) {
  IDRIS2RC2_Array *a = (IDRIS2RC2_Array *)array;
  int64_t i = idris2rc2_extractInt(index);
  idris2rc2_spin_lock(&a->lock);
  IDRIS2RC2_Value *result = idris2rc2_dup(a->items[i]);
  idris2rc2_spin_unlock(&a->lock);
  return result;
}

IDRIS2RC2_Value *idris2rc2_Data_IOArray_Prims_prim__arraySet(
    IDRIS2RC2_Value *erased, IDRIS2RC2_Value *array, IDRIS2RC2_Value *index,
    IDRIS2RC2_Value *v, IDRIS2RC2_Value *world) {
  IDRIS2RC2_Array *a = (IDRIS2RC2_Array *)array;
  int64_t i = idris2rc2_extractInt(index);
  idris2rc2_dup(v);
  idris2rc2_spin_lock(&a->lock);
  IDRIS2RC2_Value *old = a->items[i];
  a->items[i] = v;
  idris2rc2_spin_unlock(&a->lock);
  idris2rc2_drop(old);
  return NULL;
}

IDRIS2RC2_String const idris2rc2_osString = {
    IDRIS2RC2_STOCKVAL(IDRIS2RC2_TAG_STRING),
    sizeof(IDRIS2RC2_OS_NAME) - 1, IDRIS2RC2_OS_NAME
};

/* Kept in sync by hand with the "rc2" literal
   Compiler/RC2/ConstFold.idr's constExtPrimValue folds
   prim__codegen calls into at compile time -- update both if this
   value ever changes. */
IDRIS2RC2_String const idris2rc2_codegenString = {
    IDRIS2RC2_STOCKVAL(IDRIS2RC2_TAG_STRING), sizeof("rc2") - 1, "rc2"};

IDRIS2RC2_Value *idris2rc2_Prelude_IO_prim__onCollectAny(
    IDRIS2RC2_Value *anyPtr, IDRIS2RC2_Value *onFree, IDRIS2RC2_Value *world) {
  IDRIS2RC2_GCPointer *r = IDRIS2RC2_NEW_CELL(IDRIS2RC2_GCPointer);
  r->header.tag = IDRIS2RC2_TAG_GCPOINTER;
  r->p = idris2rc2_dup(anyPtr);
  r->onCollect = (IDRIS2RC2_Closure *)idris2rc2_dup(onFree);
  return (IDRIS2RC2_Value *)r;
}

// The typed form only has the erased pointee type in front.
IDRIS2RC2_Value *idris2rc2_Prelude_IO_prim__onCollect(IDRIS2RC2_Value *erased,
						      IDRIS2RC2_Value *anyPtr,
						      IDRIS2RC2_Value *onFree,
						      IDRIS2RC2_Value *world) {
  return idris2rc2_Prelude_IO_prim__onCollectAny(anyPtr, onFree, world);
}

// ---- the stack of a thread that runs Idris code (rc2/doc/concurrency.md,
// "Design: thread stacks") ----

// What a thread gets when the main thread's stack limit is unlimited.
#define IDRIS2RC2_THREAD_STACK_UNLIMITED ((size_t)16 << 20)

static pthread_once_t threadStackOnce = PTHREAD_ONCE_INIT;
static pthread_attr_t threadAttr;
static size_t threadStack; // 0: pthread_create's own default

// A number of bytes, or a number followed by K, M or G (powers of 1024),
// either case, which a B or iB may follow (256M, 256MB, 256MiB).
static bool parseSize(const char *s, size_t *size) {
  if (*s < '0' || *s > '9') return false;
  char *end;
  errno = 0;
  unsigned long long n = strtoull(s, &end, 10);
  if (errno != 0) return false;
  int shift = 0;
  switch (*end) {
  case 'k': case 'K': shift = 10; end++; break;
  case 'm': case 'M': shift = 20; end++; break;
  case 'g': case 'G': shift = 30; end++; break;
  }
  if (shift != 0 && *end == 'i' && (end[1] == 'B' || end[1] == 'b')) end += 2;
  else if (shift != 0 && (*end == 'B' || *end == 'b')) end++;
  if (*end != '\0' || n > (SIZE_MAX >> shift)) return false;
  *size = (size_t)n << shift;
  return true;
}

static void threadStackInit(void) {
  size_t size = 0;
  const char *e = getenv("IDRIS2RC2_THREAD_STACK");
  if (e && *e) {
    if (parseSize(e, &size)) {
      if (size == 0) return;
    } else {
      fprintf(stderr,
              "idris2rc2: IDRIS2RC2_THREAD_STACK=\"%s\" is not a size (bytes, or a number with K, M or G); ignored\n", e);
    }
  }
  if (size == 0) {
    struct rlimit rl;
    if (getrlimit(RLIMIT_STACK, &rl) == 0 && rl.rlim_cur != RLIM_INFINITY)
      size = (size_t)rl.rlim_cur;
    else
      size = IDRIS2RC2_THREAD_STACK_UNLIMITED;
  }
  // As glibc treats the limit: no less than the smallest stack, and whole
  // pages (macOS takes nothing else).
  if (size < (size_t)PTHREAD_STACK_MIN) size = (size_t)PTHREAD_STACK_MIN;
  size_t page = (size_t)sysconf(_SC_PAGESIZE);
  if (size <= SIZE_MAX - page) size = (size + page - 1) / page * page;
  if (pthread_attr_init(&threadAttr) != 0) return;
  if (pthread_attr_setstacksize(&threadAttr, size) != 0) {
    pthread_attr_destroy(&threadAttr);
    return;
  }
  threadStack = size;
}

void idris2rc2_threadCreate(pthread_t *tid, void *(*start)(void *), void *arg) {
  pthread_once(&threadStackOnce, threadStackInit);
  int err = pthread_create(tid, threadStack != 0 ? &threadAttr : NULL, start, arg);
  IDRIS2RC2_VERIFY(err == 0, "pthread_create failed: %d (thread stack: %zu bytes, see IDRIS2RC2_THREAD_STACK)", err,
                   threadStack);
}

// prelude/Prelude/IO.idr's `prim__fork` is declared with a generic
// `%foreign "C:refc_fork"` (not gated behind any codegen-tag whitelist --
// literally the bare C symbol name every C backend is expected to
// provide), so it reaches us regardless of the "RC2"/"RefC"/"C" FFI-tag
// mechanism rc2/Emit.idr otherwise uses to reuse RefC-tagged primitives.
// RefC's own implementation (support/refc/threads.c) is itself just a
// stub that prints a message and exits. rc2's refcount is atomic (see
// rc2/doc/concurrency.md), so this is real: pthread_create, detached --
// `threadWait` (the only thing that could join it) is scheme-only in
// upstream System.Concurrency.idr, unreachable from any C backend, so a
// detached fire-and-forget thread matches what's actually usable here.
static void *idris2rc2_threadTrampoline(void *arg) {
  // `fct : PrimIO ()` is `(1 w : %World) -> ()` -- a single application
  // of the erased world token runs it, same as idris2rc2_teardown's
  // GCPointer onCollect case (memory.c) does for its own bare PrimIO ().
  IDRIS2RC2_Value *result =
      idris2rc2_applyClosure((IDRIS2RC2_Value *)arg, NULL);
  idris2rc2_drop(result);
  return NULL;
}

void *idris2rc2_fork(IDRIS2RC2_Closure *fct) {
  idris2rc2_enableMultiThreading();
  // Prelude.IO's generated prim__fork wrapper drops its own reference to
  // fct right after this call returns (the ordinary "FFI call consumed
  // its argument" convention) -- but the spawned thread keeps using the
  // same pointer well past that. Without this dup, the caller-side drop
  // can free fct out from under the still-running thread.
  idris2rc2_dup((IDRIS2RC2_Value *)fct);
  pthread_t tid;
  idris2rc2_threadCreate(&tid, idris2rc2_threadTrampoline, fct);
  pthread_detach(tid);
  // ThreadID is `[external]` (CFUser: identity pass-through, see
  // Compiler.RC2.EmitUtil's packCFType/extractValue for CFUser), so any
  // valid IDRIS2RC2_Value* works, and threadWait can never read it (see
  // above) -- but it still needs to actually be freed once dropped.
  // IDRIS2RC2_TAG_THREADID (datatypes.h) embeds tid directly rather than
  // wrapping a separately malloc'd pthread_t*, which would leak 8 bytes on
  // every single fork.
  return (IDRIS2RC2_Value *)idris2rc2_mkThreadID(tid);
}

// Thin adapter satisfying the fixed, un-namespaced symbol name Prelude.IO's
// %foreign "C:refc_fork" declaration mandates (see ioprims.h) -- the real
// implementation lives in idris2rc2_fork, matching rc2's own naming
// convention everywhere else.
void *refc_fork(IDRIS2RC2_Closure *fct) { return idris2rc2_fork(fct); }
