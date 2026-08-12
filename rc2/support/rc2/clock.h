#pragma once

// System.Clock support, ported from RefC's support/refc/clock.c -- these
// are the exact symbol names Clock.idr's `%foreign "RefC:..."`
// declarations expect (rc2 reuses the "RefC" FFI tag, see Emit.idr's
// `ffiTags`). OSClock is an opaque `[external]` Idris type (CFUser at the
// CFType level), so it's passed around as a bare IDRIS2RC2_Value* -- no
// dedicated wrapper struct needed, just a boxed Bits64 nanosecond count
// (or NULL for an unimplemented optional clock), exactly like RefC.

#include "datatypes.h"

IDRIS2RC2_Value *clockTimeMonotonic(void);
IDRIS2RC2_Value *clockTimeUtc(void);
IDRIS2RC2_Value *clockTimeProcess(void);
IDRIS2RC2_Value *clockTimeThread(void);
IDRIS2RC2_Value *clockTimeGcCpu(void);
IDRIS2RC2_Value *clockTimeGcReal(void);

int clockValid(IDRIS2RC2_Value *clock);
uint64_t clockSecond(IDRIS2RC2_Value *clock);
uint64_t clockNanosecond(IDRIS2RC2_Value *clock);
