#include "idris2rc2_strings.h"
#include "memory.h"
#include "runtime.h"
#include "util.h"
#include "utf8.h"

IDRIS2RC2_Value *idris2rc2_strTail(IDRIS2RC2_Value *input) {
  IDRIS2RC2_String *s = (IDRIS2RC2_String *)input;
  size_t byteLen = strlen(s->str);
  size_t offset = idris2rc2_utf8ByteOffsetOfChar(s->str, byteLen, 1);
  if (offset >= byteLen)
    return (IDRIS2RC2_Value *)&idris2rc2_emptyStringValue;
  IDRIS2RC2_String *r = idris2rc2_mkEmptyString(byteLen - offset + 1);
  memcpy(r->str, s->str + offset, byteLen - offset);
  return (IDRIS2RC2_Value *)r;
}

IDRIS2RC2_Value *idris2rc2_strReverse(IDRIS2RC2_Value *str) {
  IDRIS2RC2_String *in = (IDRIS2RC2_String *)str;
  size_t byteLen = strlen(in->str);
  size_t n = idris2rc2_utf8Length(in->str, byteLen);
  // Per-character byte offsets in original order, so the second pass can
  // copy whole characters (not bytes) into their mirrored position --
  // reversal preserves total byte length, but not a fixed per-character
  // width, so a plain two-pointer byte swap would scramble multi-byte
  // characters' own internal byte order.
  size_t *offsets = malloc((n + 1) * sizeof(size_t));
  IDRIS2RC2_VERIFY(offsets, "malloc failed");
  size_t offset = 0;
  for (size_t i = 0; i < n; i++) {
    offsets[i] = offset;
    size_t consumed;
    idris2rc2_utf8DecodeAt(in->str, byteLen, offset, &consumed);
    offset += consumed;
  }
  offsets[n] = byteLen;
  IDRIS2RC2_String *r = idris2rc2_mkEmptyString(byteLen + 1);
  size_t outPos = 0;
  for (size_t i = n; i > 0; i--) {
    size_t start = offsets[i - 1], width = offsets[i] - offsets[i - 1];
    memcpy(r->str + outPos, in->str + start, width);
    outPos += width;
  }
  free(offsets);
  return (IDRIS2RC2_Value *)r;
}

IDRIS2RC2_Value *idris2rc2_strIndex(IDRIS2RC2_Value *str, IDRIS2RC2_Value *i) {
  IDRIS2RC2_String *s = (IDRIS2RC2_String *)str;
  size_t byteLen = strlen(s->str);
  int64_t idx = idris2rc2_extractInt(i);
  size_t offset = idris2rc2_utf8ByteOffsetOfChar(s->str, byteLen, (size_t)idx);
  size_t consumed;
  return idris2rc2_mkChar(idris2rc2_utf8DecodeAt(s->str, byteLen, offset, &consumed));
}

IDRIS2RC2_Value *idris2rc2_strCons(IDRIS2RC2_Value *c, IDRIS2RC2_Value *str) {
  IDRIS2RC2_String *s = (IDRIS2RC2_String *)str;
  size_t byteLen = strlen(s->str);
  uint32_t cp = idris2rc2_to_char(c);
  int cpLen = idris2rc2_utf8EncodeLen(cp);
  IDRIS2RC2_String *r = idris2rc2_mkEmptyString((size_t)cpLen + byteLen + 1);
  idris2rc2_utf8EncodeInto(cp, r->str);
  memcpy(r->str + cpLen, s->str, byteLen);
  return (IDRIS2RC2_Value *)r;
}

IDRIS2RC2_Value *idris2rc2_strAppend(IDRIS2RC2_Value *a, IDRIS2RC2_Value *b) {
  size_t la = strlen(((IDRIS2RC2_String *)a)->str);
  size_t lb = strlen(((IDRIS2RC2_String *)b)->str);
  IDRIS2RC2_String *r = idris2rc2_mkEmptyString(la + lb + 1);
  memcpy(r->str, ((IDRIS2RC2_String *)a)->str, la);
  memcpy(r->str + la, ((IDRIS2RC2_String *)b)->str, lb);
  return (IDRIS2RC2_Value *)r;
}

IDRIS2RC2_Value *idris2rc2_strSubstr(IDRIS2RC2_Value *start, IDRIS2RC2_Value *len, IDRIS2RC2_Value *s) {
  IDRIS2RC2_String *in = (IDRIS2RC2_String *)s;
  size_t byteLen = strlen(in->str);
  int64_t startIdx = idris2rc2_extractInt(start);
  int64_t lenIdx = idris2rc2_extractInt(len);
  if (startIdx < 0 || lenIdx < 0)
    return (IDRIS2RC2_Value *)idris2rc2_mkEmptyString(1);
  size_t startByte = idris2rc2_utf8ByteOffsetOfChar(in->str, byteLen, (size_t)startIdx);
  // Walk onward from startByte for lenIdx more characters, rather than
  // computing (startIdx + lenIdx) up front and re-scanning from byte 0 --
  // avoids a redundant full rescan and sidesteps startIdx+lenIdx overflow
  // on a pathologically large `len`.
  size_t offset = startByte;
  for (int64_t i = 0; i < lenIdx && offset < byteLen; i++) {
    size_t consumed;
    idris2rc2_utf8DecodeAt(in->str, byteLen, offset, &consumed);
    offset += consumed;
  }
  size_t outLen = offset - startByte;
  IDRIS2RC2_String *r = idris2rc2_mkEmptyString(outLen + 1);
  memcpy(r->str, in->str + startByte, outLen);
  return (IDRIS2RC2_Value *)r;
}

char *fastPack(IDRIS2RC2_Value *charList) {
  size_t byteLen = 0;
  IDRIS2RC2_Constructor *cur = (IDRIS2RC2_Constructor *)charList;
  while (cur != NULL) {
    byteLen += (size_t)idris2rc2_utf8EncodeLen(idris2rc2_to_char(cur->args[0]));
    cur = (IDRIS2RC2_Constructor *)cur->args[1];
  }
  char *out = malloc(byteLen + 1);
  IDRIS2RC2_VERIFY(out, "malloc failed");
  size_t pos = 0;
  cur = (IDRIS2RC2_Constructor *)charList;
  while (cur != NULL) {
    pos += (size_t)idris2rc2_utf8EncodeInto(idris2rc2_to_char(cur->args[0]), out + pos);
    cur = (IDRIS2RC2_Constructor *)cur->args[1];
  }
  out[byteLen] = '\0';
  return out;
}

IDRIS2RC2_Value *fastPackFixed(IDRIS2RC2_Value *charList) {
  size_t byteLen = 0;
  IDRIS2RC2_Constructor *cur = (IDRIS2RC2_Constructor *)charList;
  while (cur != NULL) {
    byteLen += (size_t)idris2rc2_utf8EncodeLen(idris2rc2_to_char(cur->args[0]));
    cur = (IDRIS2RC2_Constructor *)cur->args[1];
  }
  IDRIS2RC2_String *r = idris2rc2_mkEmptyString(byteLen + 1);
  size_t pos = 0;
  cur = (IDRIS2RC2_Constructor *)charList;
  while (cur != NULL) {
    pos += (size_t)idris2rc2_utf8EncodeInto(idris2rc2_to_char(cur->args[0]), r->str + pos);
    cur = (IDRIS2RC2_Constructor *)cur->args[1];
  }
  r->str[byteLen] = '\0';
  return (IDRIS2RC2_Value *)r;
}

IDRIS2RC2_Value *fastUnpack(char *str) {
  size_t byteLen = strlen(str);
  if (byteLen == 0)
    return NULL;
  size_t offset = 0, consumed;
  IDRIS2RC2_Constructor *head = idris2rc2_newConstructor(2, 1);
  head->args[0] = idris2rc2_mkChar(idris2rc2_utf8DecodeAt(str, byteLen, offset, &consumed));
  offset += consumed;
  IDRIS2RC2_Constructor *cur = head;
  while (offset < byteLen) {
    IDRIS2RC2_Constructor *next = idris2rc2_newConstructor(2, 1);
    next->args[0] = idris2rc2_mkChar(idris2rc2_utf8DecodeAt(str, byteLen, offset, &consumed));
    offset += consumed;
    cur->args[1] = (IDRIS2RC2_Value *)next;
    cur = next;
  }
  cur->args[1] = NULL;
  return (IDRIS2RC2_Value *)head;
}

char *fastConcat(IDRIS2RC2_Value *strList) {
  size_t total = 0;
  IDRIS2RC2_Constructor *cur = (IDRIS2RC2_Constructor *)strList;
  while (cur != NULL) {
    total += strlen(((IDRIS2RC2_String *)cur->args[0])->str);
    cur = (IDRIS2RC2_Constructor *)cur->args[1];
  }
  char *out = malloc(total + 1);
  IDRIS2RC2_VERIFY(out, "malloc failed");
  size_t offset = 0;
  cur = (IDRIS2RC2_Constructor *)strList;
  while (cur != NULL) {
    char *s = ((IDRIS2RC2_String *)cur->args[0])->str;
    size_t l = strlen(s);
    memcpy(out + offset, s, l);
    offset += l;
    cur = (IDRIS2RC2_Constructor *)cur->args[1];
  }
  out[total] = '\0';
  return out;
}

IDRIS2RC2_Value *fastConcatFixed(IDRIS2RC2_Value *strList) {
  size_t total = 0;
  IDRIS2RC2_Constructor *cur = (IDRIS2RC2_Constructor *)strList;
  while (cur != NULL) {
    total += strlen(((IDRIS2RC2_String *)cur->args[0])->str);
    cur = (IDRIS2RC2_Constructor *)cur->args[1];
  }
  IDRIS2RC2_String *r = idris2rc2_mkEmptyString(total + 1);
  size_t offset = 0;
  cur = (IDRIS2RC2_Constructor *)strList;
  while (cur != NULL) {
    char *s = ((IDRIS2RC2_String *)cur->args[0])->str;
    size_t l = strlen(s);
    memcpy(r->str + offset, s, l);
    offset += l;
    cur = (IDRIS2RC2_Constructor *)cur->args[1];
  }
  r->str[total] = '\0';
  return (IDRIS2RC2_Value *)r;
}

typedef struct {
  char *str;
  size_t len; // byte length of str, cached so Next doesn't rescan for NUL
  size_t pos; // byte offset, always a character boundary
} IDRIS2RC2_StringIter;

IDRIS2RC2_Value *stringIteratorNew(char *str) {
  size_t l = strlen(str);
  IDRIS2RC2_StringIter *it = malloc(sizeof(IDRIS2RC2_StringIter));
  IDRIS2RC2_VERIFY(it, "malloc failed");
  it->str = malloc(l + 1);
  IDRIS2RC2_VERIFY(it->str, "malloc failed");
  memcpy(it->str, str, l + 1);
  it->len = l;
  it->pos = 0;
  return (IDRIS2RC2_Value *)idris2rc2_mkGCPointer(
      it, idris2rc2_mkClosure((IDRIS2RC2_Value * (*)()) onCollectStringIterator, 2, 0));
}

IDRIS2RC2_Value *onCollectStringIterator(IDRIS2RC2_Value *ptr, void *unused) {
  IDRIS2RC2_StringIter *it = (IDRIS2RC2_StringIter *)((IDRIS2RC2_Pointer *)ptr)->p;
  free(it->str);
  free(it);
  // Own the Boxed ptr (IDRIS2RC2_Pointer*) argument the same way any
  // compiler-generated closure body owns and disposes of it (see
  // memory.c's own GCPointer teardown comment) -- this is a
  // hand-written native callback, not compiler-generated, so it has
  // to do that disposal itself rather than getting it for free from
  // RC.idr's dropUnusedOwnedVars.
  idris2rc2_drop(ptr);
  return NULL;
}

IDRIS2RC2_Value *stringIteratorToString(void *a, char *str, IDRIS2RC2_Value *it_p, IDRIS2RC2_Closure *f) {
  IDRIS2RC2_StringIter *it = ((IDRIS2RC2_GCPointer *)it_p)->p->p;
  IDRIS2RC2_Value *strVal = (IDRIS2RC2_Value *)idris2rc2_mkString(it->str + it->pos);
  return idris2rc2_applyClosure(idris2rc2_dup((IDRIS2RC2_Value *)f), strVal);
}

IDRIS2RC2_Value *stringIteratorNext(char *s, IDRIS2RC2_Value *it_p) {
  IDRIS2RC2_StringIter *it = (IDRIS2RC2_StringIter *)((IDRIS2RC2_GCPointer *)it_p)->p->p;
  if (it->pos >= it->len)
    return NULL;
  size_t consumed;
  uint32_t cp = idris2rc2_utf8DecodeAt(it->str, it->len, it->pos, &consumed);
  it->pos += consumed;
  IDRIS2RC2_Constructor *r = idris2rc2_newConstructor(2, 1);
  r->args[0] = idris2rc2_mkChar(cp);
  r->args[1] = idris2rc2_dup(it_p);
  return (IDRIS2RC2_Value *)r;
}
