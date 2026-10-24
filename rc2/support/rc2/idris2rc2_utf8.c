#include "idris2rc2_utf8.h"

// A byte >= 0x80 with the pattern 10xxxxxx is a continuation byte -- part
// of a preceding character, never a boundary of its own.
static inline int isContinuation(unsigned char b) { return (b & 0xC0) == 0x80; }

// Sequence length a lead byte claims, or 0 if it can't lead a sequence at
// all (a stray continuation byte, or 0xF5..0xFF, which UTF-8 never uses).
static inline int leadByteLen(unsigned char b) {
  if ((b & 0x80) == 0x00) return 1;
  if ((b & 0xE0) == 0xC0) return 2;
  if ((b & 0xF0) == 0xE0) return 3;
  if (b >= 0xF0 && b <= 0xF4) return 4;
  return 0;
}

// Whether a complete n-byte sequence decoded to `cp` is the shortest form
// of a Unicode scalar value: not overlong, not a surrogate, not past U+10FFFF.
static inline int isScalarOfLen(uint32_t cp, int n) {
  static const uint32_t smallest[5] = {0, 0, 0x80, 0x800, 0x10000};
  return cp >= smallest[n] && cp <= 0x10FFFF && (cp < 0xD800 || cp > 0xDFFF);
}

// Decodes the character that starts `u[0]`, of which `avail` (>= 1) bytes may
// be read. An invalid byte, or an incomplete sequence (a lead byte followed by
// fewer continuation bytes than it claims) gives U+FFFD for the lead byte and
// the continuation bytes that follow it; a complete sequence that is not a
// shortest-form scalar value (overlong, surrogate, past U+10FFFF) gives
// U+FFFD for the whole sequence. Same result as Chez Scheme.
static uint32_t decodeBounded(unsigned char const *u, size_t avail, size_t *consumed) {
  int n = leadByteLen(u[0]);
  if (n == 0) {
    *consumed = 1;
    return IDRIS2RC2_UTF8_REPLACEMENT;
  }
  uint32_t cp;
  switch (n) {
    case 1: cp = u[0]; break;
    case 2: cp = u[0] & 0x1F; break;
    case 3: cp = u[0] & 0x0F; break;
    default: cp = u[0] & 0x07; break;
  }
  int k = 1;
  while (k < n && (size_t)k < avail && isContinuation(u[k])) {
    cp = (cp << 6) | (uint32_t)(u[k] & 0x3F);
    k++;
  }
  *consumed = (size_t)k;
  return (k < n || !isScalarOfLen(cp, n)) ? IDRIS2RC2_UTF8_REPLACEMENT : cp;
}

uint32_t idris2rc2_utf8DecodeAt(char const *s, size_t byteLen, size_t offset, size_t *consumed) {
  if (offset >= byteLen) {
    *consumed = 1;
    return IDRIS2RC2_UTF8_REPLACEMENT;
  }
  return decodeBounded((unsigned char const *)s + offset, byteLen - offset, consumed);
}

uint32_t idris2rc2_utf8DecodeAtNul(char const *s, size_t offset, size_t *consumed) {
  unsigned char const *u = (unsigned char const *)s + offset;
  // Caller (stringIteratorNext) already did the O(1) EOF check itself
  // (s[pos] == '\0') before calling in, so u[0] is never the terminator
  // here. A multi-byte sequence's tail running into the NUL ends it: the
  // bytes available are those before the terminator, at most four.
  size_t avail = 1;
  while (avail < 4 && u[avail - 1] != '\0' && u[avail] != '\0') avail++;
  return decodeBounded(u, avail, consumed);
}

size_t idris2rc2_utf8Length(char const *s, size_t byteLen) {
  size_t n = 0, offset = 0;
  while (offset < byteLen) {
    size_t consumed;
    idris2rc2_utf8DecodeAt(s, byteLen, offset, &consumed);
    offset += consumed;
    n++;
  }
  return n;
}

size_t idris2rc2_utf8ByteOffsetOfChar(char const *s, size_t byteLen, size_t charIdx) {
  size_t offset = 0;
  for (size_t i = 0; i < charIdx && offset < byteLen; i++) {
    size_t consumed;
    idris2rc2_utf8DecodeAt(s, byteLen, offset, &consumed);
    offset += consumed;
  }
  return offset;
}

int idris2rc2_utf8EncodeLen(uint32_t cp) {
  if (cp < 0x80) return 1;
  if (cp < 0x800) return 2;
  if (cp < 0x10000) return 3;
  return 4;
}

int idris2rc2_utf8EncodeInto(uint32_t cp, char *out) {
  if (cp < 0x80) {
    out[0] = (char)cp;
    return 1;
  }
  if (cp < 0x800) {
    out[0] = (char)(0xC0 | (cp >> 6));
    out[1] = (char)(0x80 | (cp & 0x3F));
    return 2;
  }
  if (cp < 0x10000) {
    out[0] = (char)(0xE0 | (cp >> 12));
    out[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
    out[2] = (char)(0x80 | (cp & 0x3F));
    return 3;
  }
  out[0] = (char)(0xF0 | (cp >> 18));
  out[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
  out[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
  out[3] = (char)(0x80 | (cp & 0x3F));
  return 4;
}
