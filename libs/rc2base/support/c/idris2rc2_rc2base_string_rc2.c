#include <stddef.h>
#include <string.h>
#include "idris2rc2_util.h"
#include "idris2rc2_rc2base_string_rc2.h"

IDRIS2RC2_Value *idris2rc2_string_byte_slice(char const *s, int64_t total, int64_t off, int64_t len) {
    size_t n = total < 0 ? 0u : (size_t)total;

    size_t start = off < 0 ? 0u : (size_t)off;
    if (start > n) start = n;

    size_t take = len < 0 ? 0u : (size_t)len;
    if (take > n - start) take = n - start;

    return (IDRIS2RC2_Value *)idris2rc2_mkStringLen(s + start, take);
}
