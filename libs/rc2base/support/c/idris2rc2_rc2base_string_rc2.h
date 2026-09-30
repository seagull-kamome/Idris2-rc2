/* Distinctly named (not "string_util.h" / "str.h" / anything a system
 * or sibling-library header might also be called) and with a matching
 * include guard, so it can't shadow or be shadowed on a shared -I path.
 * Pairs with src/Data/String/RC2.idr. */
#ifndef IDRIS2RC2_RC2BASE_STRING_RC2_H
#define IDRIS2RC2_RC2BASE_STRING_RC2_H

#include "idris2rc2_datatypes.h"
#include "idris2rc2_memory.h"

/* Byte-exact substring: the `len` bytes of `s` starting at byte offset
 * `off`, as a freshly built IDRIS2RC2_String value.
 *
 * `total` is s's byte length (Data.String.RC2.byteLength), so a NUL
 * inside s is just another byte. `off`/`len` are clamped to [0, total] here, so an out-of-range
 * request can never read past the source -- it just yields a shorter
 * (possibly empty) result. Cutting inside a multi-byte UTF-8 sequence
 * is allowed and produces an invalid-at-the-edge string (the Idris
 * side documents that).
 *
 * Returns an already-fully-formed, correctly tagged Value* (via
 * idris2rc2_mkStringLen), NOT a bare char* -- same contract as
 * idris2rc2_rc2base_text_util.h's idris2rc2_TextBuffer_to_string. The paired %foreign
 * types its return as a never-constructed opaque marker so rc2's FFI
 * marshaller passes it through untouched instead of wrapping it again. */
IDRIS2RC2_Value *idris2rc2_string_byte_slice(char const *s, int64_t total, int64_t off, int64_t len);

/* The String's byte length -- the on-the-wire length, the counterpart
 * to codepoint-wise `Data.String.length`. Needed to bound loops that
 * already work in byte offsets (e.g. POSIX regex match iteration). Takes the
 * String value itself (not `->str`), and is inline so reading `len` costs
 * no call. */
static inline int64_t idris2rc2_string_byte_length(IDRIS2RC2_Value *s) {
    return (int64_t)((IDRIS2RC2_String *)s)->len;
}

/* A String of the `len` bytes at `p` (NUL bytes included), for C code that
 * hands back a pointer and a length instead of a NUL-terminated string.
 * Returns a finished Value*, like idris2rc2_string_byte_slice. */
IDRIS2RC2_Value *idris2rc2_string_from_bytes(void const *p, int64_t len);

#endif /* IDRIS2RC2_RC2BASE_STRING_RC2_H */
