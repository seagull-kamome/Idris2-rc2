#ifndef TEXT_UTIL_H
#define TEXT_UTIL_H

#include <stdlib.h>
#include <stdint.h>
#include "rc2/datatypes.h"
#include "rc2/memory.h"

typedef struct {
    int len;
    uint32_t buf[];
} idris2rc2_TextBuffer;


idris2rc2_TextBuffer* idris2rc2_TextBuffer_mkEmpty(int len);
idris2rc2_TextBuffer* idris2rc2_String_to_TextBuffer(const char* utf8_str);
idris2rc2_TextBuffer* idris2rc2_TextBuffer_append(const idris2rc2_TextBuffer* a, const idris2rc2_TextBuffer* b);

// Builds a fully-formed, correctly refcounted/tagged IDRIS2RC2_String
// directly (via idris2rc2_mkEmptyString) and returns it as a Boxed
// Value*, not a plain char*. Paired on the Idris side with a %foreign
// declaration whose return type is a locally-declared, never-
// constructed opaque type (not String, not AnyPtr) so rc2's own FFI
// marshaller (Compiler.RC2.Emit's CFUser case) passes the value
// through untouched instead of wrapping it a second time.
IDRIS2RC2_Value* idris2rc2_TextBuffer_to_string(const idris2rc2_TextBuffer* buf);

void idris2rc2_TextBuffer_free(void* p);

// Low-level escape hatch for a future mutable-builder style API (e.g.
// packing several chars into a freshly mkEmpty'd buffer before it's
// ever exposed as a Text) -- unused by the current pure API surface.
static inline void idris2rc2_TextBuffer_unsafe_write_char(idris2rc2_TextBuffer* buf, int index, uint32_t ch) {
	buf->buf[index] = ch;
}
static inline int idris2rc2_text_length(const idris2rc2_TextBuffer* buf) { return buf->len; }
static inline uint32_t idris2rc2_text_index(const idris2rc2_TextBuffer* buf, int index) { return buf->buf[index]; }

#endif
