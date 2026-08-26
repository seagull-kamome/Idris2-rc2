#pragma once

#include "datatypes.h"
#include "numeric.h"
#include "utf8.h"

// Length/indexing are Unicode-codepoint-wise, matching Idris2's own Chez
// backend (Scheme strings are codepoint sequences by spec) rather than
// upstream RefC's own byte-wise simplification -- see README.md's
// "Deliberate differences from upstream RefC".
#define idris2rc2_strLength(x)                                                     \
  (idris2rc2_mkInt64((int64_t)idris2rc2_utf8Length(                                \
      ((IDRIS2RC2_String *)(x))->str, strlen(((IDRIS2RC2_String *)(x))->str))))
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
char *fastPack(IDRIS2RC2_Value *charList)
    __attribute__((deprecated("leaks its own malloc'd buffer -- Compiler.RC2.Emit's own createCFunctions should always redirect Prelude.Types.fastPack to fastPackFixed instead, so reaching this is an rc2 bug, not something to work around (see KNOWN-BUGS.md / rc2/doc/fastpack-fix.md)")));
IDRIS2RC2_Value *fastUnpack(char *str);
char *fastConcat(IDRIS2RC2_Value *strList)
    __attribute__((deprecated("leaks its own malloc'd buffer -- Compiler.RC2.Emit's own createCFunctions should always redirect Prelude.Types.fastConcat to fastConcatFixed instead, so reaching this is an rc2 bug, not something to work around (see KNOWN-BUGS.md / rc2/doc/fastpack-fix.md)")));

// Leak-free siblings of fastPack/fastConcat above: same computation, but
// building directly into a fresh IDRIS2RC2_String via idris2rc2_mkEmptyString
// instead of returning a bare malloc'd char* for the generic CFString-return
// FFI wrapper to copy-and-never-free (that copy-and-leak is correct for a
// real external library's char* return, which the caller must not free --
// wrong only for these two, which malloc a buffer this project itself owns;
// see KNOWN-BUGS.md). Returns an already-fully-built IDRIS2RC2_Value*,
// opted into by Idris code via Prelude.Fix.RC2's `Raw` pass-through type +
// %transform, not used unless that module is imported.
IDRIS2RC2_Value *fastPackFixed(IDRIS2RC2_Value *charList);
IDRIS2RC2_Value *fastConcatFixed(IDRIS2RC2_Value *strList);

IDRIS2RC2_Value *stringIteratorNew(char *str);
IDRIS2RC2_Value *onCollectStringIterator(IDRIS2RC2_Value *ptr, void *unused);
// `f` matches the C signature our own FFI codegen actually generates for
// a CFFun-typed foreign argument (cast to IDRIS2RC2_Closure*, see
// Emit.idr's `extractValue (CFFun ...)`), not the generic Value*.
IDRIS2RC2_Value *stringIteratorToString(void *a, char *str, IDRIS2RC2_Value *it, IDRIS2RC2_Closure *f);
IDRIS2RC2_Value *stringIteratorNext(char *s, IDRIS2RC2_Value *it);
