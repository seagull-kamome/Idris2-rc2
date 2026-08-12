#pragma once

#include "datatypes.h"
#include "numeric.h"

// Strings are treated byte-wise (not Unicode-codepoint-wise) for indexing,
// matching the simplification RefC itself makes.
#define idris2rc2_strLength(x) (idris2rc2_mkInt64((int64_t)strlen(((IDRIS2RC2_String *)(x))->str)))
#define idris2rc2_strHead(x) (idris2rc2_cast_string_to_Char(x))

IDRIS2RC2_Value *idris2rc2_strTail(IDRIS2RC2_Value *str);
IDRIS2RC2_Value *idris2rc2_strReverse(IDRIS2RC2_Value *str);
IDRIS2RC2_Value *idris2rc2_strIndex(IDRIS2RC2_Value *str, IDRIS2RC2_Value *i);
IDRIS2RC2_Value *idris2rc2_strCons(IDRIS2RC2_Value *c, IDRIS2RC2_Value *str);
IDRIS2RC2_Value *idris2rc2_strAppend(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b);
IDRIS2RC2_Value *idris2rc2_strSubstr(IDRIS2RC2_Value *start, IDRIS2RC2_Value *len, IDRIS2RC2_Value *s);

// NOTE: the following names are NOT rc2-prefixed on purpose. libs/prelude
// and libs/contrib declare them via `%foreign "RefC:fastPack"` etc (with
// the literal, backend-agnostic C symbol name baked into the string), and
// %transform pragmas unconditionally rewrite `pack`/`unpack`/`concat` to
// call them. Our codegen (see Compiler/RC2/RC2.idr) treats the "RefC" FFI
// tag as directly callable, so we must provide these exact symbol names
// ourselves, using our own value representation.
char *fastPack(IDRIS2RC2_Value *charList);
IDRIS2RC2_Value *fastUnpack(char *str);
char *fastConcat(IDRIS2RC2_Value *strList);

IDRIS2RC2_Value *stringIteratorNew(char *str);
IDRIS2RC2_Value *onCollectStringIterator(IDRIS2RC2_Value *ptr, void *unused);
// `f` matches the C signature our own FFI codegen actually generates for
// a CFFun-typed foreign argument (cast to IDRIS2RC2_Closure*, see
// Emit.idr's `extractValue (CFFun ...)`), not the generic Value*.
IDRIS2RC2_Value *stringIteratorToString(void *a, char *str, IDRIS2RC2_Value *it, IDRIS2RC2_Closure *f);
IDRIS2RC2_Value *stringIteratorNext(char *s, IDRIS2RC2_Value *it);
