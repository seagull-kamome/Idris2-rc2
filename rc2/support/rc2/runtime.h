#pragma once

#include "datatypes.h"

void idris2rc2_missingForeign(void);

#define idris2rc2_isUnique(x) ((x)->header.refCount == 1)
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
