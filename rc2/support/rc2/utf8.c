#include "utf8.h"

// A byte >= 0x80 with the pattern 10xxxxxx is a continuation byte -- part
// of a preceding character, never a boundary of its own.
static inline int isContinuation(unsigned char b) { return (b & 0xC0) == 0x80; }

// Sequence length a lead byte claims, or 0 if it can't lead a sequence at
// all (a stray continuation byte, or 0xF8..0xFF, which UTF-8 never uses).
static inline int leadByteLen(unsigned char b) {
  if ((b & 0x80) == 0x00) return 1;
  if ((b & 0xE0) == 0xC0) return 2;
  if ((b & 0xF0) == 0xE0) return 3;
  if ((b & 0xF8) == 0xF0) return 4;
  return 0;
}

uint32_t idris2rc2_utf8DecodeAt(char const *s, size_t byteLen, size_t offset, size_t *consumed) {
  unsigned char const *u = (unsigned char const *)s;
  if (offset >= byteLen) {
    *consumed = 1;
    return IDRIS2RC2_UTF8_REPLACEMENT;
  }
  int n = leadByteLen(u[offset]);
  if (n == 0 || offset + (size_t)n > byteLen) {
    *consumed = 1;
    return IDRIS2RC2_UTF8_REPLACEMENT;
  }
  uint32_t cp;
  switch (n) {
    case 1: cp = u[offset]; break;
    case 2: cp = u[offset] & 0x1F; break;
    case 3: cp = u[offset] & 0x0F; break;
    default: cp = u[offset] & 0x07; break;
  }
  for (int i = 1; i < n; i++) {
    unsigned char b = u[offset + (size_t)i];
    if (!isContinuation(b)) {
      *consumed = 1;
      return IDRIS2RC2_UTF8_REPLACEMENT;
    }
    cp = (cp << 6) | (uint32_t)(b & 0x3F);
  }
  *consumed = (size_t)n;
  return cp;
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
