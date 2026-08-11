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
