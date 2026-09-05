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

IDRIS2RC2_Value *idris2rc2_fastPackFixed(IDRIS2RC2_Value *charList) {
  size_t byteLen = 0;
  IDRIS2RC2_Constructor *cur = (IDRIS2RC2_Constructor *)charList;
  while (cur != NULL) {
    byteLen += (size_t)idris2rc2_utf8EncodeLen(idris2rc2_to_char(cur->args[0]));
    cur = (IDRIS2RC2_Constructor *)cur->args[1];
  }
  // No explicit trailing-NUL write here (unlike this file's own
  // idris2rc2_strTail/strReverse/strCons/strAppend/strSubstr, which
  // never need one to begin with, only ever memcpy-ing real payload
  // bytes): idris2rc2_mkEmptyString's own malloc'd path already
  // memset()s the whole buffer to zero, so byte `byteLen` (right after
  // the last one this loop writes) is already '\0'. Byte-for-byte
  // required for the byteLen == 0 case specifically -- mkEmptyString(1)
  // hands back the shared immortal idris2rc2_emptyStringValue (a
  // `const` static, `str = ""`), and a `r->str[0] = '\0'` write here
  // would be a write into read-only memory (confirmed by an actual
  // SIGSEGV once this function started being reached unconditionally
  // for every fastPack call, including `pack []`, project-wide -- see
  // rc2/doc/fastpack-fix.md).
  IDRIS2RC2_String *r = idris2rc2_mkEmptyString(byteLen + 1);
  size_t pos = 0;
  cur = (IDRIS2RC2_Constructor *)charList;
  while (cur != NULL) {
    pos += (size_t)idris2rc2_utf8EncodeInto(idris2rc2_to_char(cur->args[0]), r->str + pos);
    cur = (IDRIS2RC2_Constructor *)cur->args[1];
  }
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

IDRIS2RC2_Value *idris2rc2_fastConcatFixed(IDRIS2RC2_Value *strList) {
  size_t total = 0;
  IDRIS2RC2_Constructor *cur = (IDRIS2RC2_Constructor *)strList;
  while (cur != NULL) {
    total += strlen(((IDRIS2RC2_String *)cur->args[0])->str);
    cur = (IDRIS2RC2_Constructor *)cur->args[1];
  }
  // See idris2rc2_fastPackFixed's own matching comment: no explicit trailing-NUL
  // write here either, and for the identical reason -- mkEmptyString(1)
  // (the total == 0 case, e.g. `concat []`) hands back the shared
  // immortal idris2rc2_emptyStringValue, a `const` static, so writing
  // to it would fault; the malloc'd path is already memset() to zero,
  // so the terminator's already correct without an explicit write.
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
  return (IDRIS2RC2_Value *)r;
}

// stringIteratorNew/Next/ToString implement upstream's own
// Data.String.Iterator FFI primitives (libs/contrib's `RefC:` foreign
// names). Upstream's own Idris-level API always re-supplies the original
// string alongside the iterator at every call site (`uncons : (str :
// String) -> (1 it : StringIterator str) -> UnconsResult str`), by
// design -- its own module doc explains this is precisely so backends
// "can just use an integer offset" for the iterator itself. rc2's own
// reference counting (see the `annotate` pass) already guarantees that
// re-supplied `str`/`s` argument stays alive for the whole call, since
// it's a live local reachable at the call site by construction -- so the
// iterator has nothing of its own left to own or keep alive. It is
// therefore represented as a bare tagged-integer byte offset
// (idris2rc2_mkBits32/idris2rc2_to_u32, the same unboxed-scalar scheme
// idris2rc2_mkChar itself uses), not a heap allocation: no malloc, no
// GC-pointer wrapper, no finalizer, and idris2rc2_dup/idris2rc2_drop on it
// are already no-ops (unboxed values are recognized by idris2rc2_is_unboxed
// and skipped by both).
//
// IDRIS2RC2_String caches no byte length (see datatypes.h), only a NUL
// terminator, so stepping the offset can't call strlen() on every single
// character (that would turn an O(n) walk into O(n^2)). Both
// stringIteratorNext's own EOF check (s[pos] == '\0') and its decode step
// (idris2rc2_utf8DecodeAtNul) instead lean on the NUL terminator directly,
// each in O(1)/O(1-per-char).

IDRIS2RC2_Value *stringIteratorNew(char *str) {
  // str is genuinely unused: see this section's own header comment above
  // -- the string is re-supplied fresh at every subsequent Next/ToString
  // call, so there's nothing to copy or remember here beyond pos=0.
  (void)str;
  return idris2rc2_mkBits32(0);
}

IDRIS2RC2_Value *stringIteratorToString(void *a, char *str, IDRIS2RC2_Value *it_p, IDRIS2RC2_Closure *f) {
  uint32_t pos = idris2rc2_to_u32(it_p);
  IDRIS2RC2_Value *strVal = (IDRIS2RC2_Value *)idris2rc2_mkString(str + pos);
  return idris2rc2_applyClosure(idris2rc2_dup((IDRIS2RC2_Value *)f), strVal);
}

IDRIS2RC2_Value *stringIteratorNext(char *s, IDRIS2RC2_Value *it_p) {
  uint32_t pos = idris2rc2_to_u32(it_p);
  if (s[pos] == '\0')
    return NULL;
  size_t consumed;
  uint32_t cp = idris2rc2_utf8DecodeAtNul(s, (size_t)pos, &consumed);
  IDRIS2RC2_Constructor *r = idris2rc2_newConstructor(2, 1);
  r->args[0] = idris2rc2_mkChar(cp);
  // A fresh tagged integer, not idris2rc2_dup(it_p): the old value was a
  // GC-pointer needing a refcount bump to keep both the old and new
  // iterator handles valid; this one is unboxed, so there's no shared
  // allocation to protect at all -- a plain new tag word is both correct
  // and cheaper.
  r->args[1] = idris2rc2_mkBits32(pos + (uint32_t)consumed);
  return (IDRIS2RC2_Value *)r;
}
