#include "buffer.h"
#include "util.h"

#include <stdlib.h>
#include <string.h>

void *newBuffer(int bytes) {
  size_t size = sizeof(IDRIS2RC2_RawBuffer) + (size_t)bytes * sizeof(uint8_t);

  IDRIS2RC2_RawBuffer *buf = malloc(size);
  if (buf == NULL) {
    return NULL;
  }

  buf->size = bytes;
  memset(buf->data, 0, bytes);

  return (void *)buf;
}

static void assert_valid_range(IDRIS2RC2_RawBuffer *buf, int64_t offset, int64_t len) {
  IDRIS2RC2_VERIFY(offset >= 0, "offset (%lld) < 0", (long long)offset);
  IDRIS2RC2_VERIFY(len >= 0, "len (%lld) < 0", (long long)len);
  IDRIS2RC2_VERIFY(offset + len <= buf->size,
                    "offset (%lld) + len (%lld) > buf.size (%lld)",
                    (long long)offset, (long long)len, (long long)buf->size);
}

int getBufferSize(void *buffer) { return ((IDRIS2RC2_RawBuffer *)buffer)->size; }

void copyBuffer(void *from, int from_offset, int len, void *to, int to_offset) {
  IDRIS2RC2_RawBuffer *bfrom = from;
  IDRIS2RC2_RawBuffer *bto = to;

  assert_valid_range(bfrom, from_offset, len);
  assert_valid_range(bto, to_offset, len);

  memcpy(bto->data + to_offset, bfrom->data + from_offset, len);
}

void setBufferUIntLE(void *b, int loc, uint64_t val, size_t len) {
  assert_valid_range((IDRIS2RC2_RawBuffer *)b, loc, len);
  while (len--) {
    ((IDRIS2RC2_RawBuffer *)b)->data[loc++] = (char)(uint8_t)val;
    val >>= 8;
  }
}

uint64_t getBufferUIntLE(void *b, int loc, size_t len) {
  assert_valid_range((IDRIS2RC2_RawBuffer *)b, loc, len);
  uint64_t r = 0;
  loc += len;
  while (len--) {
    r <<= 8;
    r += (uint8_t)(((IDRIS2RC2_RawBuffer *)b)->data[--loc]);
  }
  return r;
}

void setBufferDouble(void *buffer, int loc, double val) {
  union {
    double d;
    uint64_t i;
  } tmp;
  tmp.d = val;
  setBufferUIntLE(buffer, loc, tmp.i, 8);
}

double getBufferDouble(void *buffer, int loc) {
  union {
    double d;
    uint64_t i;
  } tmp;
  tmp.i = getBufferUIntLE(buffer, loc, 8);
  return tmp.d;
}

void setBufferString(void *buffer, int loc, char *str) {
  IDRIS2RC2_RawBuffer *b = buffer;
  size_t len = strlen(str);
  assert_valid_range(b, loc, len);
  memcpy((b->data) + loc, str, len);
}

char *getBufferString(void *buffer, int loc, int len) {
  IDRIS2RC2_RawBuffer *b = buffer;
  assert_valid_range(b, loc, len);
  char *s = (char *)(b->data + loc);
  char *rs = malloc((size_t)len + 1);
  IDRIS2RC2_VERIFY(rs, "malloc failed");
  strncpy(rs, s, len);
  rs[len] = '\0';
  return rs;
}
