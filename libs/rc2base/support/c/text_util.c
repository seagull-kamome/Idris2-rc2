#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include "rc2/util.h"
#include "rc2/utf8.h"
#include "./text_util.h"

// ///////////////////////////////////////////////////////////////////////////

idris2rc2_TextBuffer* idris2rc2_TextBuffer_mkEmpty(int len) {
    idris2rc2_TextBuffer* buffer = malloc(
		    sizeof(idris2rc2_TextBuffer) + sizeof(uint32_t) * len);
    IDRIS2RC2_VERIFY(buffer, "allocation failed");
    buffer->len = len;
    return buffer;
}


idris2rc2_TextBuffer* idris2rc2_String_to_TextBuffer(const char* utf8_str) {
    size_t byteLen = strlen(utf8_str);
    size_t len = idris2rc2_utf8Length(utf8_str, byteLen);
    idris2rc2_TextBuffer* buffer = idris2rc2_TextBuffer_mkEmpty((int)len);
    size_t offset = 0;
    for (size_t i = 0; i < len; i++) {
        size_t consumed;
        buffer->buf[i] = idris2rc2_utf8DecodeAt(utf8_str, byteLen, offset, &consumed);
        offset += consumed;
    }
    return buffer;
}


idris2rc2_TextBuffer* idris2rc2_TextBuffer_append(const idris2rc2_TextBuffer* a, const idris2rc2_TextBuffer* b) {
    idris2rc2_TextBuffer* r = idris2rc2_TextBuffer_mkEmpty(a->len + b->len);
    memcpy(r->buf, a->buf, sizeof(uint32_t) * (size_t)a->len);
    memcpy(r->buf + a->len, b->buf, sizeof(uint32_t) * (size_t)b->len);
    return r;
}


IDRIS2RC2_Value* idris2rc2_TextBuffer_to_string(const idris2rc2_TextBuffer* buf) {
    size_t outLen = 0;
    for (int i = 0; i < buf->len; i++) {
        outLen += idris2rc2_utf8EncodeLen(buf->buf[i]);
    }
    // idris2rc2_mkEmptyString(1) returns a shared, immutable empty-string
    // singleton (memory.c) rather than a fresh writable allocation -- for
    // outLen == 0 that singleton must be returned as-is, never written
    // into below.
    if (outLen == 0) {
        return (IDRIS2RC2_Value*)idris2rc2_mkEmptyString(1);
    }
    IDRIS2RC2_String* r = idris2rc2_mkEmptyString(outLen + 1);
    char* p = r->str;
    for (int i = 0; i < buf->len; i++) {
        p += idris2rc2_utf8EncodeInto(buf->buf[i], p);
    }
    *p = '\0';
    return (IDRIS2RC2_Value*)r;
}


void idris2rc2_TextBuffer_free(void* p) {
    free(p);
}
