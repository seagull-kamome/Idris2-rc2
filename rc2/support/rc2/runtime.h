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
extern char const idris2rc2_constr__percentWorld[]; // see runtime.c's own comment
IDRIS2RC2_Value *idris2rc2_freshWorld(void); // see runtime.c's own comment

// idris2-src's own support/c headers are missing a handful of prototypes
// for functions their own .c files implement just fine and libs/ own
// %foreign declarations name directly (one-line upstream header omissions,
// not missing symbols -- confirmed by grepping every support/c/*.c
// definition against its own .h; a handful more turned up the same way but
// aren't actually %foreign-referenced from anywhere in libs/, so aren't
// declared here). Each compiles to an implicit-declaration error under
// -Werror wherever nothing else already declared it first. Whole-program
// compilation never notices (DeadCode/upstream's own reachability fetch
// always removes an unused one first); --inc rc2 does, since it compiles
// every module's own toIR regardless of local reachability -- see
// rc2/doc/incremental-compile.md's "Major finding" section. Predeclared
// here, same fix as idris2rc2_constr____gt above, rather than patching
// idris2-src itself (out of scope for this project to maintain a fork of).
int idris2_fileIsTTY(FILE *f);                    // support/c/idris_file.c
int idris2_enableRawMode(void);                   // support/c/idris_support.c
void idris2_resetRawMode(void);                   // support/c/idris_support.c
void idrnet_free(void *ptr);                      // support/c/idris_memory.c
