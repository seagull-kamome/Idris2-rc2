#pragma once

#include "idris2rc2_datatypes.h"

// Names mirror `idris2_<mangled qualified name>` as produced by
// Compiler/RC2/RC2.idr's handling of AExtPrim nodes (see the whitelist
// there), just with the idris2rc2_ prefix instead of idris2_.

IDRIS2RC2_Value *idris2rc2_Data_IORef_prim__newIORef(IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_Data_IORef_prim__readIORef(IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_Data_IORef_prim__writeIORef(IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *);

IDRIS2RC2_Value *idris2rc2_Data_IOArray_Prims_prim__newArray(IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_Data_IOArray_Prims_prim__arrayGet(IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_Data_IOArray_Prims_prim__arraySet(IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *);

/* The OS this translation unit is compiled for. Exactly one
   IDRIS2RC2_OS_IS_* macro is defined. The compiler folds `prim__os` to a
   constant under `target-os` (rc2/doc/directives.md) and checks it against
   the macro here, so the names must match Compiler/RC2/TargetOs.idr. */
#if defined(_WIN32)
#define IDRIS2RC2_OS_NAME "windows"
#define IDRIS2RC2_OS_IS_WINDOWS 1
#elif defined(__APPLE__) || defined(__MACH__)
#define IDRIS2RC2_OS_NAME "macOS"
#define IDRIS2RC2_OS_IS_MACOS 1
#elif defined(__linux__)
#define IDRIS2RC2_OS_NAME "Linux"
#define IDRIS2RC2_OS_IS_LINUX 1
#elif defined(__FreeBSD__)
#define IDRIS2RC2_OS_NAME "FreeBSD"
#define IDRIS2RC2_OS_IS_FREEBSD 1
#elif defined(__OpenBSD__)
#define IDRIS2RC2_OS_NAME "OpenBSD"
#define IDRIS2RC2_OS_IS_OPENBSD 1
#elif defined(__NetBSD__)
#define IDRIS2RC2_OS_NAME "NetBSD"
#define IDRIS2RC2_OS_IS_NETBSD 1
#elif defined(__unix__) || defined(__unix)
#define IDRIS2RC2_OS_NAME "Unix"
#define IDRIS2RC2_OS_IS_UNIX 1
#else
#define IDRIS2RC2_OS_NAME "Other"
#define IDRIS2RC2_OS_IS_OTHER 1
#endif

extern IDRIS2RC2_String const idris2rc2_osString;
extern IDRIS2RC2_String const idris2rc2_codegenString;
#define idris2rc2_System_Info_prim__os() ((IDRIS2RC2_Value *)&idris2rc2_osString)
#define idris2rc2_System_Info_prim__codegen() ((IDRIS2RC2_Value *)&idris2rc2_codegenString)

IDRIS2RC2_Value *idris2rc2_Prelude_IO_prim__onCollect(IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *);
IDRIS2RC2_Value *idris2rc2_Prelude_IO_prim__onCollectAny(IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *);

void *idris2rc2_fork(IDRIS2RC2_Closure *fct);
// See ioprims.c for why this bare (un-namespaced) name is required --
// it's a thin adapter to idris2rc2_fork above, not the real logic.
void *refc_fork(IDRIS2RC2_Closure *fct);

// Not an AExtPrim (no compiler-side whitelist entry, unlike the
// idris2rc2_Data_IORef_prim__* trio above) -- an ordinary %foreign
// function `Data.IORef.RC2.casIORef` (libs/rc2base) calls directly,
// plain-named like idris2rc2_fork above. See ioprims.c for the
// Maybe-returning ownership contract.
IDRIS2RC2_Value *idris2rc2_ioref_cas(IDRIS2RC2_Value *, IDRIS2RC2_Value *ioref, IDRIS2RC2_Value *expected, IDRIS2RC2_Value *desired);
