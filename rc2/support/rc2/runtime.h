#pragma once

#include "datatypes.h"

void idris2rc2_missingForeign(void);

// Acquire ordering pairs with idris2rc2_drop's release-decrement: once this
// observes 1, the calling thread is provably the sole owner (the release
// fence of whichever thread dropped the second-to-last reference is now
// visible), so in-place mutation of `x` needs no further synchronization.
// Kept as a macro (not a typed inline function) so it stays generic over any
// struct starting with an IDRIS2RC2_Header `header` field, matching every
// call site's own concrete pointer type (e.g. IDRIS2RC2_Closure *).
#define idris2rc2_isUnique(x)                                                \
  (atomic_load_explicit(&(x)->header.refCount, memory_order_acquire) == 1)
// Why not atomic-safe against a concurrent second reference: trampoline's
// non-unique branch and idris2rc2_tailcallApplyClosure/
// idris2rc2_dropReuseConstructor (runtime.c) still decrement refCount
// without checking for a zero result, relying on the single-threaded
// invariant that "not unique" means refCount was >=2 going in. This is
// unreachable today (refc_fork is still a stub, no real OS threads run
// concurrently) but must be revisited once real thread spawning lands.
void idris2rc2_dropReuseConstructor(IDRIS2RC2_Constructor *c);

IDRIS2RC2_Value *idris2rc2_applyClosure(IDRIS2RC2_Value *closure, IDRIS2RC2_Value *arg);
IDRIS2RC2_Value *idris2rc2_tailcallApplyClosure(IDRIS2RC2_Value *closure, IDRIS2RC2_Value *arg);
IDRIS2RC2_Value *idris2rc2_trampoline(IDRIS2RC2_Value *v);

int64_t idris2rc2_extractInt(IDRIS2RC2_Value *v);

IDRIS2RC2_Value *idris2rc2_crash(IDRIS2RC2_Value *msg);

// Predeclared name strings for Idris2's "typecase" feature -- see the
// definition site in runtime.c for why these need to exist independent of
// any particular program's own constructor-name declarations.
extern char const idris2rc2_constr_Int[];
extern char const idris2rc2_constr_Int8[];
extern char const idris2rc2_constr_Int16[];
extern char const idris2rc2_constr_Int32[];
extern char const idris2rc2_constr_Int64[];
extern char const idris2rc2_constr_Bits8[];
extern char const idris2rc2_constr_Bits16[];
extern char const idris2rc2_constr_Bits32[];
extern char const idris2rc2_constr_Bits64[];
extern char const idris2rc2_constr_Double[];
extern char const idris2rc2_constr_Integer[];
extern char const idris2rc2_constr_Char[];
extern char const idris2rc2_constr_String[];
extern char const idris2rc2_constr____gt[];
