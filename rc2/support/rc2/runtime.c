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
typedef IDRIS2RC2_Value *(*const IDRIS2RC2_FUNSTAR)(IDRIS2RC2_Value **);

// When adding arities above 8, extend this switch and MaxExtractFunArgs in
// Compiler/RC2/RC2.idr accordingly.
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
  }
}

IDRIS2RC2_Value *idris2rc2_trampoline(IDRIS2RC2_Value *it) {
  while (it && !idris2rc2_is_unboxed(it) && it->header.tag == IDRIS2RC2_TAG_CLOSURE) {
    IDRIS2RC2_Closure *c = (IDRIS2RC2_Closure *)it;
    if (c->filled < c->arity)
      break;
    it = idris2rc2_dispatchClosure(c);
    if (idris2rc2_isUnique(c))
      free(c);
    else
      --c->header.refCount;
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
  --c->header.refCount;

  return (IDRIS2RC2_Value *)nc;
}

IDRIS2RC2_Value *idris2rc2_applyClosure(IDRIS2RC2_Value *c, IDRIS2RC2_Value *arg) {
  return idris2rc2_trampoline(idris2rc2_tailcallApplyClosure(c, arg));
}

void idris2rc2_dropReuseConstructor(IDRIS2RC2_Constructor *c) {
  if (!c)
    return;
  IDRIS2RC2_VERIFY(c->header.refCount > 0, "refCount %d", (int)c->header.refCount);
  if (--c->header.refCount == 0)
    free(c);
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
