#include "ioprims.h"
#include "memory.h"
#include "runtime.h"

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
