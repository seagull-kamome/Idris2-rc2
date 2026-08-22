#ifndef TEXT_UTIL_H
#define TEXT_UTIL_H

#include <stdlib.h>
#include <stdint.h>

typedef struct {
    size_t len;
    uint32_t buf[];
} idris2rc2_TextBuffer;

idris2rc2_TextBuffer* idris2rc2_utf8_to_codepoints(const char* utf8_str);
void idris2rc2_free_text_buffer(idris2rc2_TextBuffer* buf);

#endif
