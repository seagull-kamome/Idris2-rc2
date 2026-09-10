#include <stddef.h>
#include <string.h>
#include "rc2/util.h"
#include "./string_rc2.h"

IDRIS2RC2_Value *idris2rc2_string_byte_slice(char const *s, int off, int len) {
    size_t total = strlen(s);

    size_t start = off < 0 ? 0u : (size_t)off;
    if (start > total) start = total;

    size_t take = len < 0 ? 0u : (size_t)len;
    if (take > total - start) take = total - start;

    /* idris2rc2_mkEmptyString(1) hands back the shared immutable
     * empty-string singleton (memory.c) -- must be returned as-is for
     * the empty case, never written into. Mirrors
     * idris2rc2_TextBuffer_to_string's own outLen == 0 guard. */
    if (take == 0)
        return (IDRIS2RC2_Value *)idris2rc2_mkEmptyString(1);

    IDRIS2RC2_String *r = idris2rc2_mkEmptyString(take + 1);
    memcpy(r->str, s + start, take);
    r->str[take] = '\0';
    return (IDRIS2RC2_Value *)r;
}

int idris2rc2_string_byte_length(char const *s) {
    return (int)strlen(s);
}
