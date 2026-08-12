#pragma once

#include "datatypes.h"

// Names mirror `idris2_<mangled qualified name>` as produced by
// Compiler/RC2/RC2.idr's handling of AExtPrim nodes (see the whitelist
// there), just with the idris2rc2_ prefix instead of idris2_.

IDRIS2RC2_Value *idris2rc2_Data_IORef_prim__newIORef(IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *);
#define idris2rc2_Data_IORef_prim__readIORef(erased, ioref, world)                  \
  (idris2rc2_dup(((IDRIS2RC2_IORef *)(ioref))->v))
IDRIS2RC2_Value *idris2rc2_Data_IORef_prim__writeIORef(IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *);

IDRIS2RC2_Value *idris2rc2_Data_IOArray_Prims_prim__newArray(IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *);
#define idris2rc2_Data_IOArray_Prims_prim__arrayGet(erased, array, i, world)        \
  (idris2rc2_dup(((IDRIS2RC2_Array *)(array))->items[idris2rc2_extractInt(i)]))
IDRIS2RC2_Value *idris2rc2_Data_IOArray_Prims_prim__arraySet(IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *);

extern IDRIS2RC2_String const idris2rc2_osString;
extern IDRIS2RC2_String const idris2rc2_codegenString;
#define idris2rc2_System_Info_prim__os() ((IDRIS2RC2_Value *)&idris2rc2_osString)
#define idris2rc2_System_Info_prim__codegen() ((IDRIS2RC2_Value *)&idris2rc2_codegenString)

IDRIS2RC2_Value *idris2rc2_Prelude_IO_prim__onCollect(IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_Prelude_IO_prim__onCollectAny(IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *);

// See ioprims.c for why this bare (un-namespaced) name is required.
void *refc_fork(IDRIS2RC2_Closure *fct);
