#include "ioprims.h"
#include "memory.h"
#include "runtime.h"
#include "util.h"

#include <pthread.h>
#include <stdio.h>

IDRIS2RC2_Value *idris2rc2_Data_IORef_prim__newIORef(IDRIS2RC2_Value *erased,
                                                       IDRIS2RC2_Value *v,
                                                       IDRIS2RC2_Value *world) {
  IDRIS2RC2_IORef *r = IDRIS2RC2_NEW(IDRIS2RC2_IORef);
  r->header.tag = IDRIS2RC2_TAG_IOREF;
  r->v = idris2rc2_dup(v);
  return (IDRIS2RC2_Value *)r;
}

IDRIS2RC2_Value *idris2rc2_Data_IORef_prim__writeIORef(IDRIS2RC2_Value *erased,
                                                         IDRIS2RC2_Value *ioref,
                                                         IDRIS2RC2_Value *newValue,
                                                         IDRIS2RC2_Value *world) {
  IDRIS2RC2_IORef *r = (IDRIS2RC2_IORef *)ioref;
  idris2rc2_dup(newValue);
  IDRIS2RC2_Value *old = r->v;
  r->v = newValue;
  idris2rc2_drop(old);
  return NULL;
}

IDRIS2RC2_Value *idris2rc2_Data_IOArray_Prims_prim__newArray(
    IDRIS2RC2_Value *erased, IDRIS2RC2_Value *length, IDRIS2RC2_Value *v,
    IDRIS2RC2_Value *world) {
  int len = (int)idris2rc2_extractInt(length);
  IDRIS2RC2_Array *a = idris2rc2_mkArray(len);
  for (int i = 0; i < len; i++)
    a->items[i] = idris2rc2_dup(v);
  return (IDRIS2RC2_Value *)a;
}

IDRIS2RC2_Value *idris2rc2_Data_IOArray_Prims_prim__arraySet(
    IDRIS2RC2_Value *erased, IDRIS2RC2_Value *array, IDRIS2RC2_Value *index,
    IDRIS2RC2_Value *v, IDRIS2RC2_Value *world) {
  IDRIS2RC2_Array *a = (IDRIS2RC2_Array *)array;
  int64_t i = idris2rc2_extractInt(index);
  idris2rc2_drop(a->items[i]);
  a->items[i] = idris2rc2_dup(v);
  return NULL;
}

IDRIS2RC2_String const idris2rc2_osString = {
    IDRIS2RC2_STOCKVAL(IDRIS2RC2_TAG_STRING),
#if defined(_WIN32)
    "windows"
#elif defined(__APPLE__) || defined(__MACH__)
    "macOS"
#elif defined(__linux__)
    "Linux"
#elif defined(__FreeBSD__)
    "FreeBSD"
#elif defined(__OpenBSD__)
    "OpenBSD"
#elif defined(__NetBSD__)
    "NetBSD"
#elif defined(__unix__) || defined(__unix)
    "Unix"
#else
    "Other"
#endif
};

/* Kept in sync by hand with the "rc2" literal
   Compiler/RC2/ConstExtPrim.idr's constExtPrimValue folds
   prim__codegen calls into at compile time -- update both if this
   value ever changes. */
IDRIS2RC2_String const idris2rc2_codegenString = {
    IDRIS2RC2_STOCKVAL(IDRIS2RC2_TAG_STRING), "rc2"};

IDRIS2RC2_Value *idris2rc2_Prelude_IO_prim__onCollect(IDRIS2RC2_Value *erased,
                                                        IDRIS2RC2_Value *anyPtr,
                                                        IDRIS2RC2_Value *onFree,
                                                        IDRIS2RC2_Value *world) {
  IDRIS2RC2_GCPointer *r = IDRIS2RC2_NEW(IDRIS2RC2_GCPointer);
  r->header.tag = IDRIS2RC2_TAG_GCPOINTER;
  r->p = (IDRIS2RC2_Pointer *)idris2rc2_dup(anyPtr);
  r->onCollect = (IDRIS2RC2_Closure *)onFree;
  return (IDRIS2RC2_Value *)r;
}

IDRIS2RC2_Value *idris2rc2_Prelude_IO_prim__onCollectAny(IDRIS2RC2_Value *anyPtr,
                                                           IDRIS2RC2_Value *onFree,
                                                           IDRIS2RC2_Value *world) {
  IDRIS2RC2_GCPointer *r = IDRIS2RC2_NEW(IDRIS2RC2_GCPointer);
  r->header.tag = IDRIS2RC2_TAG_GCPOINTER;
  r->p = (IDRIS2RC2_Pointer *)idris2rc2_dup(anyPtr);
  r->onCollect = (IDRIS2RC2_Closure *)onFree;
  return (IDRIS2RC2_Value *)r;
}

// prelude/Prelude/IO.idr's `prim__fork` is declared with a generic
// `%foreign "C:refc_fork"` (not gated behind any codegen-tag whitelist --
// literally the bare C symbol name every C backend is expected to
// provide), so it reaches us regardless of the "RC2"/"RefC"/"C" FFI-tag
// mechanism rc2/Emit.idr otherwise uses to reuse RefC-tagged primitives.
// RefC's own implementation (support/refc/threads.c) is itself just a
// stub that prints a message and exits -- true thread support was never
// implemented there either. rc2's refcount is now atomic (see
// rc2/doc/concurrency.md), so this is real: pthread_create, detached --
// `threadWait` (the only thing that could join it) is scheme-only in
// upstream System.Concurrency.idr, unreachable from any C backend, so a
// detached fire-and-forget thread matches what's actually usable here.
static void *idris2rc2_threadTrampoline(void *arg) {
  // `fct : PrimIO ()` is `(1 w : %World) -> ()` -- a single application
  // of the erased world token runs it, same as idris2rc2_teardown's
  // GCPointer onCollect case (memory.c) does for its own bare PrimIO ().
  IDRIS2RC2_Value *result = idris2rc2_applyClosure((IDRIS2RC2_Value *)arg, NULL);
  idris2rc2_drop(result);
  return NULL;
}

void *idris2rc2_fork(IDRIS2RC2_Closure *fct) {
  // Prelude.IO's generated prim__fork wrapper drops its own reference to
  // fct right after this call returns (the ordinary "FFI call consumed
  // its argument" convention) -- but the spawned thread keeps using the
  // same pointer well past that. Without this dup, the caller-side drop
  // can free fct out from under the still-running thread.
  idris2rc2_dup((IDRIS2RC2_Value *)fct);
  pthread_t tid;
  int err = pthread_create(&tid, NULL, idris2rc2_threadTrampoline, fct);
  IDRIS2RC2_VERIFY(err == 0, "pthread_create failed: %d", err);
  pthread_detach(tid);
  // ThreadID is `[external]` (CFUser: identity pass-through, see
  // Compiler.RC2.EmitUtil's packCFType/extractValue for CFUser), so any
  // valid IDRIS2RC2_Value* works. threadWait can never read it (see
  // above), so a plain IDRIS2RC2_Pointer is enough -- no dedicated tag.
  pthread_t *heapTid = malloc(sizeof(pthread_t));
  IDRIS2RC2_VERIFY(heapTid, "malloc failed");
  *heapTid = tid;
  return idris2rc2_mkPointer(heapTid);
}

// Thin adapter satisfying the fixed, un-namespaced symbol name Prelude.IO's
// %foreign "C:refc_fork" declaration mandates (see ioprims.h) -- the real
// implementation lives in idris2rc2_fork, matching rc2's own naming
// convention everywhere else.
void *refc_fork(IDRIS2RC2_Closure *fct) {
  return idris2rc2_fork(fct);
}
