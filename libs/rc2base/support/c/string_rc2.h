/* Distinctly named (not "string_util.h" / "str.h" / anything a system
 * or sibling-library header might also be called) and with a matching
 * include guard, so it can't shadow or be shadowed on a shared -I path.
 * Pairs with src/Data/String/RC2.idr. */
#ifndef RC2BASE_STRING_RC2_H
#define RC2BASE_STRING_RC2_H

#include "rc2/datatypes.h"
#include "rc2/memory.h"

/* Byte-exact substring: the `len` bytes of `s` starting at byte offset
 * `off`, as a freshly built IDRIS2RC2_String value.
 *
 * `off`/`len` are clamped to [0, strlen(s)] here, so an out-of-range
 * request can never read past the source -- it just yields a shorter
 * (possibly empty) result. Cutting inside a multi-byte UTF-8 sequence
 * is allowed and produces an invalid-at-the-edge string (the Idris
 * side documents that).
 *
 * Returns an already-fully-formed, correctly tagged Value* (via
 * idris2rc2_mkEmptyString), NOT a bare char* -- same contract as
 * text_util.h's idris2rc2_TextBuffer_to_string. The paired %foreign
 * types its return as a never-constructed opaque marker so rc2's FFI
 * marshaller passes it through untouched instead of wrapping it again. */
IDRIS2RC2_Value *idris2rc2_string_byte_slice(char const *s, int off, int len);

/* strlen(s) as an int -- the on-the-wire byte length, the counterpart
 * to codepoint-wise `Data.String.length`. Needed to bound loops that
 * already work in byte offsets (e.g. POSIX regex match iteration). */
int idris2rc2_string_byte_length(char const *s);

#endif /* RC2BASE_STRING_RC2_H */
