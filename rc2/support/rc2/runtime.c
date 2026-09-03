#include "runtime.h"
#include "memory.h"
#include "util.h"

#include <stdio.h>
#include <stdlib.h>

void idris2rc2_missingForeign(void) {
  fprintf(stderr, "idris2rc2: foreign function declared but not defined\n");
  exit(1);
}

typedef IDRIS2RC2_Value *(*const IDRIS2RC2_FUN0)();
typedef IDRIS2RC2_Value *(*const IDRIS2RC2_FUN1)(IDRIS2RC2_Value *);
typedef IDRIS2RC2_Value *(*const IDRIS2RC2_FUN2)(IDRIS2RC2_Value *, IDRIS2RC2_Value *);
typedef IDRIS2RC2_Value *(*const IDRIS2RC2_FUN3)(IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *);
typedef IDRIS2RC2_Value *(*const IDRIS2RC2_FUN4)(IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *);
typedef IDRIS2RC2_Value *(*const IDRIS2RC2_FUN5)(IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *);
typedef IDRIS2RC2_Value *(*const IDRIS2RC2_FUN6)(IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *);
typedef IDRIS2RC2_Value *(*const IDRIS2RC2_FUN7)(IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *);
typedef IDRIS2RC2_Value *(*const IDRIS2RC2_FUN8)(IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *);
typedef IDRIS2RC2_Value *(*const IDRIS2RC2_FUN9)(IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *);
typedef IDRIS2RC2_Value *(*const IDRIS2RC2_FUN10)(IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *);
typedef IDRIS2RC2_Value *(*const IDRIS2RC2_FUN11)(IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *);
typedef IDRIS2RC2_Value *(*const IDRIS2RC2_FUN12)(IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *);
typedef IDRIS2RC2_Value *(*const IDRIS2RC2_FUN13)(IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *);
typedef IDRIS2RC2_Value *(*const IDRIS2RC2_FUN14)(IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *);
typedef IDRIS2RC2_Value *(*const IDRIS2RC2_FUN15)(IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *);
typedef IDRIS2RC2_Value *(*const IDRIS2RC2_FUN16)(IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *);
typedef IDRIS2RC2_Value *(*const IDRIS2RC2_FUN17)(IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *);
typedef IDRIS2RC2_Value *(*const IDRIS2RC2_FUN18)(IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *);
typedef IDRIS2RC2_Value *(*const IDRIS2RC2_FUN19)(IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *);
typedef IDRIS2RC2_Value *(*const IDRIS2RC2_FUN20)(IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *,
                                      IDRIS2RC2_Value *, IDRIS2RC2_Value *, IDRIS2RC2_Value *);
typedef IDRIS2RC2_Value *(*const IDRIS2RC2_FUNSTAR)(IDRIS2RC2_Value **);

// When adding arities above 20, extend this switch and MaxExtractFunArgs in
// Compiler/RC2/EmitUtil.idr accordingly.
static inline IDRIS2RC2_Value *idris2rc2_dispatchClosure(IDRIS2RC2_Closure *c) {
  IDRIS2RC2_Value **const xs = c->args;
  switch (c->arity) {
  default:
    return (*(IDRIS2RC2_FUNSTAR)c->fn)(xs);
  case 0:
    return (*(IDRIS2RC2_FUN0)c->fn)();
  case 1:
    return (*(IDRIS2RC2_FUN1)c->fn)(xs[0]);
  case 2:
    return (*(IDRIS2RC2_FUN2)c->fn)(xs[0], xs[1]);
  case 3:
    return (*(IDRIS2RC2_FUN3)c->fn)(xs[0], xs[1], xs[2]);
  case 4:
    return (*(IDRIS2RC2_FUN4)c->fn)(xs[0], xs[1], xs[2], xs[3]);
  case 5:
    return (*(IDRIS2RC2_FUN5)c->fn)(xs[0], xs[1], xs[2], xs[3], xs[4]);
  case 6:
    return (*(IDRIS2RC2_FUN6)c->fn)(xs[0], xs[1], xs[2], xs[3], xs[4], xs[5]);
  case 7:
    return (*(IDRIS2RC2_FUN7)c->fn)(xs[0], xs[1], xs[2], xs[3], xs[4], xs[5], xs[6]);
  case 8:
    return (*(IDRIS2RC2_FUN8)c->fn)(xs[0], xs[1], xs[2], xs[3], xs[4], xs[5], xs[6],
                               xs[7]);
  case 9:
    return (*(IDRIS2RC2_FUN9)c->fn)(xs[0], xs[1], xs[2], xs[3], xs[4], xs[5], xs[6],
                               xs[7], xs[8]);
  case 10:
    return (*(IDRIS2RC2_FUN10)c->fn)(xs[0], xs[1], xs[2], xs[3], xs[4], xs[5], xs[6],
                               xs[7], xs[8], xs[9]);
  case 11:
    return (*(IDRIS2RC2_FUN11)c->fn)(xs[0], xs[1], xs[2], xs[3], xs[4], xs[5], xs[6],
                               xs[7], xs[8], xs[9], xs[10]);
  case 12:
    return (*(IDRIS2RC2_FUN12)c->fn)(xs[0], xs[1], xs[2], xs[3], xs[4], xs[5], xs[6],
                               xs[7], xs[8], xs[9], xs[10], xs[11]);
  case 13:
    return (*(IDRIS2RC2_FUN13)c->fn)(xs[0], xs[1], xs[2], xs[3], xs[4], xs[5], xs[6],
                               xs[7], xs[8], xs[9], xs[10], xs[11], xs[12]);
  case 14:
    return (*(IDRIS2RC2_FUN14)c->fn)(xs[0], xs[1], xs[2], xs[3], xs[4], xs[5], xs[6],
                               xs[7], xs[8], xs[9], xs[10], xs[11], xs[12], xs[13]);
  case 15:
    return (*(IDRIS2RC2_FUN15)c->fn)(xs[0], xs[1], xs[2], xs[3], xs[4], xs[5], xs[6],
                               xs[7], xs[8], xs[9], xs[10], xs[11], xs[12], xs[13],
                               xs[14]);
  case 16:
    return (*(IDRIS2RC2_FUN16)c->fn)(xs[0], xs[1], xs[2], xs[3], xs[4], xs[5], xs[6],
                               xs[7], xs[8], xs[9], xs[10], xs[11], xs[12], xs[13],
                               xs[14], xs[15]);
  case 17:
    return (*(IDRIS2RC2_FUN17)c->fn)(xs[0], xs[1], xs[2], xs[3], xs[4], xs[5], xs[6],
                               xs[7], xs[8], xs[9], xs[10], xs[11], xs[12], xs[13],
                               xs[14], xs[15], xs[16]);
  case 18:
    return (*(IDRIS2RC2_FUN18)c->fn)(xs[0], xs[1], xs[2], xs[3], xs[4], xs[5], xs[6],
                               xs[7], xs[8], xs[9], xs[10], xs[11], xs[12], xs[13],
                               xs[14], xs[15], xs[16], xs[17]);
  case 19:
    return (*(IDRIS2RC2_FUN19)c->fn)(xs[0], xs[1], xs[2], xs[3], xs[4], xs[5], xs[6],
                               xs[7], xs[8], xs[9], xs[10], xs[11], xs[12], xs[13],
                               xs[14], xs[15], xs[16], xs[17], xs[18]);
  case 20:
    return (*(IDRIS2RC2_FUN20)c->fn)(xs[0], xs[1], xs[2], xs[3], xs[4], xs[5], xs[6],
                               xs[7], xs[8], xs[9], xs[10], xs[11], xs[12], xs[13],
                               xs[14], xs[15], xs[16], xs[17], xs[18], xs[19]);
  }
}

// Fast path for idris2rc2_applyClosure only (see its own call site) --
// dispatches a non-unique closure's FINAL argument straight into `fn`
// without ever materializing the grown IDRIS2RC2_Closure that
// idris2rc2_tailcallApplyClosure's own non-unique branch would build
// just to hand it to idris2rc2_trampoline for immediate dispatch and
// teardown. `c->filled` existing args are dup'd (same as that branch
// would do) and passed positionally ahead of `arg`; case N therefore
// dups exactly N-1 of them (xs[0..N-2]) with `arg` last -- mirrors
// idris2rc2_dispatchClosure's own switch shape, so extending it above
// arity 20 needs the same extension there too.
static inline IDRIS2RC2_Value *idris2rc2_dispatchWithExtra(IDRIS2RC2_Closure *c, IDRIS2RC2_Value *arg) {
  IDRIS2RC2_Value **const xs = c->args;
  switch (c->arity) {
  case 1:
    return (*(IDRIS2RC2_FUN1)c->fn)(arg);
  case 2:
    return (*(IDRIS2RC2_FUN2)c->fn)(idris2rc2_dup(xs[0]), arg);
  case 3:
    return (*(IDRIS2RC2_FUN3)c->fn)(idris2rc2_dup(xs[0]), idris2rc2_dup(xs[1]), arg);
  case 4:
    return (*(IDRIS2RC2_FUN4)c->fn)(idris2rc2_dup(xs[0]), idris2rc2_dup(xs[1]), idris2rc2_dup(xs[2]),
                               arg);
  case 5:
    return (*(IDRIS2RC2_FUN5)c->fn)(idris2rc2_dup(xs[0]), idris2rc2_dup(xs[1]), idris2rc2_dup(xs[2]),
                               idris2rc2_dup(xs[3]), arg);
  case 6:
    return (*(IDRIS2RC2_FUN6)c->fn)(idris2rc2_dup(xs[0]), idris2rc2_dup(xs[1]), idris2rc2_dup(xs[2]),
                               idris2rc2_dup(xs[3]), idris2rc2_dup(xs[4]), arg);
  case 7:
    return (*(IDRIS2RC2_FUN7)c->fn)(idris2rc2_dup(xs[0]), idris2rc2_dup(xs[1]), idris2rc2_dup(xs[2]),
                               idris2rc2_dup(xs[3]), idris2rc2_dup(xs[4]), idris2rc2_dup(xs[5]),
                               arg);
  case 8:
    return (*(IDRIS2RC2_FUN8)c->fn)(idris2rc2_dup(xs[0]), idris2rc2_dup(xs[1]), idris2rc2_dup(xs[2]),
                               idris2rc2_dup(xs[3]), idris2rc2_dup(xs[4]), idris2rc2_dup(xs[5]),
                               idris2rc2_dup(xs[6]), arg);
  case 9:
    return (*(IDRIS2RC2_FUN9)c->fn)(idris2rc2_dup(xs[0]), idris2rc2_dup(xs[1]), idris2rc2_dup(xs[2]),
                               idris2rc2_dup(xs[3]), idris2rc2_dup(xs[4]), idris2rc2_dup(xs[5]),
                               idris2rc2_dup(xs[6]), idris2rc2_dup(xs[7]), arg);
  case 10:
    return (*(IDRIS2RC2_FUN10)c->fn)(idris2rc2_dup(xs[0]), idris2rc2_dup(xs[1]), idris2rc2_dup(xs[2]),
                               idris2rc2_dup(xs[3]), idris2rc2_dup(xs[4]), idris2rc2_dup(xs[5]),
                               idris2rc2_dup(xs[6]), idris2rc2_dup(xs[7]), idris2rc2_dup(xs[8]),
                               arg);
  case 11:
    return (*(IDRIS2RC2_FUN11)c->fn)(idris2rc2_dup(xs[0]), idris2rc2_dup(xs[1]), idris2rc2_dup(xs[2]),
                               idris2rc2_dup(xs[3]), idris2rc2_dup(xs[4]), idris2rc2_dup(xs[5]),
                               idris2rc2_dup(xs[6]), idris2rc2_dup(xs[7]), idris2rc2_dup(xs[8]),
                               idris2rc2_dup(xs[9]), arg);
  case 12:
    return (*(IDRIS2RC2_FUN12)c->fn)(idris2rc2_dup(xs[0]), idris2rc2_dup(xs[1]), idris2rc2_dup(xs[2]),
                               idris2rc2_dup(xs[3]), idris2rc2_dup(xs[4]), idris2rc2_dup(xs[5]),
                               idris2rc2_dup(xs[6]), idris2rc2_dup(xs[7]), idris2rc2_dup(xs[8]),
                               idris2rc2_dup(xs[9]), idris2rc2_dup(xs[10]), arg);
  case 13:
    return (*(IDRIS2RC2_FUN13)c->fn)(idris2rc2_dup(xs[0]), idris2rc2_dup(xs[1]), idris2rc2_dup(xs[2]),
                               idris2rc2_dup(xs[3]), idris2rc2_dup(xs[4]), idris2rc2_dup(xs[5]),
                               idris2rc2_dup(xs[6]), idris2rc2_dup(xs[7]), idris2rc2_dup(xs[8]),
                               idris2rc2_dup(xs[9]), idris2rc2_dup(xs[10]), idris2rc2_dup(xs[11]),
                               arg);
  case 14:
    return (*(IDRIS2RC2_FUN14)c->fn)(idris2rc2_dup(xs[0]), idris2rc2_dup(xs[1]), idris2rc2_dup(xs[2]),
                               idris2rc2_dup(xs[3]), idris2rc2_dup(xs[4]), idris2rc2_dup(xs[5]),
                               idris2rc2_dup(xs[6]), idris2rc2_dup(xs[7]), idris2rc2_dup(xs[8]),
                               idris2rc2_dup(xs[9]), idris2rc2_dup(xs[10]), idris2rc2_dup(xs[11]),
                               idris2rc2_dup(xs[12]), arg);
  case 15:
    return (*(IDRIS2RC2_FUN15)c->fn)(idris2rc2_dup(xs[0]), idris2rc2_dup(xs[1]), idris2rc2_dup(xs[2]),
                               idris2rc2_dup(xs[3]), idris2rc2_dup(xs[4]), idris2rc2_dup(xs[5]),
                               idris2rc2_dup(xs[6]), idris2rc2_dup(xs[7]), idris2rc2_dup(xs[8]),
                               idris2rc2_dup(xs[9]), idris2rc2_dup(xs[10]), idris2rc2_dup(xs[11]),
                               idris2rc2_dup(xs[12]), idris2rc2_dup(xs[13]), arg);
  case 16:
    return (*(IDRIS2RC2_FUN16)c->fn)(idris2rc2_dup(xs[0]), idris2rc2_dup(xs[1]), idris2rc2_dup(xs[2]),
                               idris2rc2_dup(xs[3]), idris2rc2_dup(xs[4]), idris2rc2_dup(xs[5]),
                               idris2rc2_dup(xs[6]), idris2rc2_dup(xs[7]), idris2rc2_dup(xs[8]),
                               idris2rc2_dup(xs[9]), idris2rc2_dup(xs[10]), idris2rc2_dup(xs[11]),
                               idris2rc2_dup(xs[12]), idris2rc2_dup(xs[13]), idris2rc2_dup(xs[14]),
                               arg);
  case 17:
    return (*(IDRIS2RC2_FUN17)c->fn)(idris2rc2_dup(xs[0]), idris2rc2_dup(xs[1]), idris2rc2_dup(xs[2]),
                               idris2rc2_dup(xs[3]), idris2rc2_dup(xs[4]), idris2rc2_dup(xs[5]),
                               idris2rc2_dup(xs[6]), idris2rc2_dup(xs[7]), idris2rc2_dup(xs[8]),
                               idris2rc2_dup(xs[9]), idris2rc2_dup(xs[10]), idris2rc2_dup(xs[11]),
                               idris2rc2_dup(xs[12]), idris2rc2_dup(xs[13]), idris2rc2_dup(xs[14]),
                               idris2rc2_dup(xs[15]), arg);
  case 18:
    return (*(IDRIS2RC2_FUN18)c->fn)(idris2rc2_dup(xs[0]), idris2rc2_dup(xs[1]), idris2rc2_dup(xs[2]),
                               idris2rc2_dup(xs[3]), idris2rc2_dup(xs[4]), idris2rc2_dup(xs[5]),
                               idris2rc2_dup(xs[6]), idris2rc2_dup(xs[7]), idris2rc2_dup(xs[8]),
                               idris2rc2_dup(xs[9]), idris2rc2_dup(xs[10]), idris2rc2_dup(xs[11]),
                               idris2rc2_dup(xs[12]), idris2rc2_dup(xs[13]), idris2rc2_dup(xs[14]),
                               idris2rc2_dup(xs[15]), idris2rc2_dup(xs[16]), arg);
  case 19:
    return (*(IDRIS2RC2_FUN19)c->fn)(idris2rc2_dup(xs[0]), idris2rc2_dup(xs[1]), idris2rc2_dup(xs[2]),
                               idris2rc2_dup(xs[3]), idris2rc2_dup(xs[4]), idris2rc2_dup(xs[5]),
                               idris2rc2_dup(xs[6]), idris2rc2_dup(xs[7]), idris2rc2_dup(xs[8]),
                               idris2rc2_dup(xs[9]), idris2rc2_dup(xs[10]), idris2rc2_dup(xs[11]),
                               idris2rc2_dup(xs[12]), idris2rc2_dup(xs[13]), idris2rc2_dup(xs[14]),
                               idris2rc2_dup(xs[15]), idris2rc2_dup(xs[16]), idris2rc2_dup(xs[17]),
                               arg);
  case 20:
    return (*(IDRIS2RC2_FUN20)c->fn)(idris2rc2_dup(xs[0]), idris2rc2_dup(xs[1]), idris2rc2_dup(xs[2]),
                               idris2rc2_dup(xs[3]), idris2rc2_dup(xs[4]), idris2rc2_dup(xs[5]),
                               idris2rc2_dup(xs[6]), idris2rc2_dup(xs[7]), idris2rc2_dup(xs[8]),
                               idris2rc2_dup(xs[9]), idris2rc2_dup(xs[10]), idris2rc2_dup(xs[11]),
                               idris2rc2_dup(xs[12]), idris2rc2_dup(xs[13]), idris2rc2_dup(xs[14]),
                               idris2rc2_dup(xs[15]), idris2rc2_dup(xs[16]), idris2rc2_dup(xs[17]),
                               idris2rc2_dup(xs[18]), arg);
  default:
    // Caller (idris2rc2_applyClosure) only reaches here for
    // 1 <= c->arity <= 20; the generic FUNSTAR arity is deliberately
    // out of scope for this fast path (falls through to the ordinary
    // mkClosure-based path instead).
    IDRIS2RC2_VERIFY(false, "idris2rc2_dispatchWithExtra: impossible arity %d", (int)c->arity);
    return NULL;
  }
}

IDRIS2RC2_Value *idris2rc2_trampoline(IDRIS2RC2_Value *it) {
  while (it && !idris2rc2_is_unboxed(it) && it->header.tag == IDRIS2RC2_TAG_CLOSURE) {
    IDRIS2RC2_Closure *c = (IDRIS2RC2_Closure *)it;
    if (c->filled < c->arity)
      break;
    it = idris2rc2_dispatchClosure(c);
    // Args were already consumed by dispatchClosure (ownership passed
    // into fn, never re-dup'd), so on reaching zero here this only ever
    // needs to free the closure shell itself -- never the full
    // idris2rc2_drop teardown (which would re-drop already-consumed
    // args). Unconditional atomic decrement (rather than an isUnique
    // check followed by a separate bare decrement) is what makes this
    // race-free once another thread can hold its own counted reference
    // to the same closure (see runtime.h's idris2rc2_isUnique comment).
    if (atomic_fetch_sub_explicit(&c->header.refCount, 1, memory_order_release) == 1) {
      atomic_thread_fence(memory_order_acquire);
      free(c);
    }
  }
  return it;
}

IDRIS2RC2_Value *idris2rc2_tailcallApplyClosure(IDRIS2RC2_Value *_c, IDRIS2RC2_Value *arg) {
  IDRIS2RC2_Closure *c = (IDRIS2RC2_Closure *)_c;

  // Unique: idris2rc2_mkClosure already reserved room for the full
  // arity, so growing by one argument is just a field write -- no
  // allocation, no copy, no free.
  if (idris2rc2_isUnique(c)) {
    c->args[c->filled] = arg;
    ++c->filled;
    return (IDRIS2RC2_Value *)c;
  }

  IDRIS2RC2_Closure *nc = idris2rc2_mkClosure(c->fn, c->arity, c->filled + 1);
  for (int i = 0; i < c->filled; ++i)
    nc->args[i] = idris2rc2_dup(c->args[i]);
  nc->args[c->filled] = arg;
  // c's own args were dup'd into nc above, not stolen -- c still owns
  // them, so (unlike trampoline's case above) the ordinary checked drop
  // is exactly right if this reference turns out to be the last one.
  idris2rc2_drop((IDRIS2RC2_Value *)c);

  return (IDRIS2RC2_Value *)nc;
}

IDRIS2RC2_Value *idris2rc2_applyClosure(IDRIS2RC2_Value *_c, IDRIS2RC2_Value *arg) {
  IDRIS2RC2_Closure *c = (IDRIS2RC2_Closure *)_c;
  // Unlike idris2rc2_tailcallApplyClosure's own non-unique branch (which
  // must keep returning an undispatched closure for its tail-call
  // callers -- see idris2rc2_dispatchWithExtra's doc comment above),
  // this wrapper always dispatches its result immediately via
  // idris2rc2_trampoline regardless of which branch runs, so a
  // non-unique closure receiving its FINAL argument can skip straight
  // to dispatch without ever materializing the grown closure that
  // would just be trampolined and torn down again right here.
  if (!idris2rc2_isUnique(c) && c->arity - c->filled == 1 &&
      c->arity >= 1 && c->arity <= 20) {
    IDRIS2RC2_Value *result = idris2rc2_dispatchWithExtra(c, arg);
    idris2rc2_drop((IDRIS2RC2_Value *)c);
    return idris2rc2_trampoline(result);
  }
  return idris2rc2_trampoline(idris2rc2_tailcallApplyClosure(_c, arg));
}

void idris2rc2_dropReuseConstructor(IDRIS2RC2_Constructor *c) {
  if (!c)
    return;
  IDRIS2RC2_VERIFY(c->header.refCount > 0, "refCount %d", (int)c->header.refCount);
  // Only ever called on a value whose uniqueness idris2rc2_isUnique has
  // already established statically (see Reuse.idr/reuse-analysis.md), so
  // no other thread can concurrently touch this refCount -- atomicity
  // here is just so the operation itself is a well-defined memory access
  // alongside every other refCount op, not a response to a real race.
  if (atomic_fetch_sub_explicit(&c->header.refCount, 1, memory_order_release) == 1) {
    atomic_thread_fence(memory_order_acquire);
    free(c);
  }
}

int64_t idris2rc2_extractInt(IDRIS2RC2_Value *v) {
  if (idris2rc2_is_unboxed(v))
    return (int64_t)((uintptr_t)v >> idris2rc2_unbox_shift);
  switch (v->header.tag) {
  case IDRIS2RC2_TAG_BITS32:
    return (int64_t)idris2rc2_to_u32(v);
  case IDRIS2RC2_TAG_BITS64:
    return (int64_t)idris2rc2_to_u64(v);
  case IDRIS2RC2_TAG_INT32:
    return (int64_t)((IDRIS2RC2_Int32 *)v)->v;
  case IDRIS2RC2_TAG_INT64:
    return idris2rc2_to_i64(v);
  case IDRIS2RC2_TAG_INTEGER:
    return (int64_t)mpz_get_si(((IDRIS2RC2_Integer *)v)->v);
  case IDRIS2RC2_TAG_DOUBLE:
    return (int64_t)idris2rc2_to_double(v);
  default:
    return -1;
  }
}

IDRIS2RC2_Value *idris2rc2_crash(IDRIS2RC2_Value *msg) {
  IDRIS2RC2_String *s = (IDRIS2RC2_String *)msg;
  fprintf(stderr, "ERROR: %s\n", s ? s->str : "(no message)");
  exit(1);
}

// Name strings for Idris2's "typecase" feature: a `Type` value pattern
// matched against a primitive type (e.g. `f : Type -> ...; f Int = ...`)
// or against the reflected function-type former `(_ -> _)` compiles down
// to an untagged constructor (ConInfo TYCON) match/build referencing a
// *name* with no backing top-level definition anywhere in the program
// (Compiler.CompileExpr.toCExpTm's `Ref fc (TyCon arity) fn` and
// `Bind fc x (Pi ...) sc` cases just synthesize a bare `CCon` on the fly).
// Since there is no definition, Compiler.RC2.RC/Emit's usual per-program
// `idris2rc2_constr_<Name>` declaration (emitted alongside a real
// `MkRCCon Nothing _ _`) never fires for these -- so, exactly as RefC's
// own runtime does (support/refc/prim.c), the whole fixed set of
// primitive-type name strings is predeclared here once, unconditionally.
char const idris2rc2_constr_Int[] = "Int";
char const idris2rc2_constr_Int8[] = "Int8";
char const idris2rc2_constr_Int16[] = "Int16";
char const idris2rc2_constr_Int32[] = "Int32";
char const idris2rc2_constr_Int64[] = "Int64";
char const idris2rc2_constr_Bits8[] = "Bits8";
char const idris2rc2_constr_Bits16[] = "Bits16";
char const idris2rc2_constr_Bits32[] = "Bits32";
char const idris2rc2_constr_Bits64[] = "Bits64";
char const idris2rc2_constr_Double[] = "Double";
char const idris2rc2_constr_Integer[] = "Integer";
char const idris2rc2_constr_Char[] = "Char";
char const idris2rc2_constr_String[] = "String";
char const idris2rc2_constr____gt[] = "->";
