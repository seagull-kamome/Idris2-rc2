#include "idris2rc2_strings.h"
#include "memory.h"
#include "runtime.h"
#include "util.h"

IDRIS2RC2_Value *idris2rc2_strTail(IDRIS2RC2_Value *input) {
  IDRIS2RC2_String *s = (IDRIS2RC2_String *)input;
  size_t l = strlen(s->str);
  if (l == 0)
    return (IDRIS2RC2_Value *)&idris2rc2_emptyStringValue;
  IDRIS2RC2_String *r = idris2rc2_mkEmptyString(l);
  memcpy(r->str, s->str + 1, l - 1);
  return (IDRIS2RC2_Value *)r;
}

IDRIS2RC2_Value *idris2rc2_strReverse(IDRIS2RC2_Value *str) {
  IDRIS2RC2_String *in = (IDRIS2RC2_String *)str;
  size_t l = strlen(in->str);
  IDRIS2RC2_String *r = idris2rc2_mkEmptyString(l + 1);
  for (size_t i = 0; i < l; i++)
    r->str[i] = in->str[l - 1 - i];
  return (IDRIS2RC2_Value *)r;
}

IDRIS2RC2_Value *idris2rc2_strIndex(IDRIS2RC2_Value *str, IDRIS2RC2_Value *i) {
  char *s = ((IDRIS2RC2_String *)str)->str;
  int64_t idx = idris2rc2_extractInt(i);
  return idris2rc2_mkChar((unsigned char)s[idx]);
}

IDRIS2RC2_Value *idris2rc2_strCons(IDRIS2RC2_Value *c, IDRIS2RC2_Value *str) {
  size_t l = strlen(((IDRIS2RC2_String *)str)->str);
  IDRIS2RC2_String *r = idris2rc2_mkEmptyString(l + 2);
  r->str[0] = (char)idris2rc2_to_char(c);
  memcpy(r->str + 1, ((IDRIS2RC2_String *)str)->str, l);
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
  char *input = ((IDRIS2RC2_String *)s)->str;
  int64_t offset = idris2rc2_extractInt(start);
  int64_t l = idris2rc2_extractInt(len);
  int64_t tailLen = (int64_t)strlen(input) - offset;
  if (offset < 0 || tailLen < 0) {
    IDRIS2RC2_String *r = idris2rc2_mkEmptyString(1);
    return (IDRIS2RC2_Value *)r;
  }
  if (tailLen < l)
    l = tailLen;
  IDRIS2RC2_String *r = idris2rc2_mkEmptyString((size_t)l + 1);
  memcpy(r->str, input + offset, (size_t)l);
  return (IDRIS2RC2_Value *)r;
}

char *fastPack(IDRIS2RC2_Value *charList) {
  size_t l = 0;
  IDRIS2RC2_Constructor *cur = (IDRIS2RC2_Constructor *)charList;
  while (cur != NULL) {
    l++;
    cur = (IDRIS2RC2_Constructor *)cur->args[1];
  }
  char *out = malloc(l + 1);
  IDRIS2RC2_VERIFY(out, "malloc failed");
  size_t i = 0;
  cur = (IDRIS2RC2_Constructor *)charList;
  while (cur != NULL) {
    out[i++] = (char)idris2rc2_to_char(cur->args[0]);
    cur = (IDRIS2RC2_Constructor *)cur->args[1];
  }
  out[l] = '\0';
  return out;
}

IDRIS2RC2_Value *fastUnpack(char *str) {
  if (str[0] == '\0')
    return NULL;
  IDRIS2RC2_Constructor *head = idris2rc2_newConstructor(2, 1);
  head->args[0] = idris2rc2_mkChar((unsigned char)str[0]);
  IDRIS2RC2_Constructor *cur = head;
  for (int i = 1; str[i] != '\0'; i++) {
    IDRIS2RC2_Constructor *next = idris2rc2_newConstructor(2, 1);
    next->args[0] = idris2rc2_mkChar((unsigned char)str[i]);
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

typedef struct {
  char *str;
  int pos;
} IDRIS2RC2_StringIter;

IDRIS2RC2_Value *stringIteratorNew(char *str) {
  size_t l = strlen(str);
  IDRIS2RC2_StringIter *it = malloc(sizeof(IDRIS2RC2_StringIter));
  IDRIS2RC2_VERIFY(it, "malloc failed");
  it->str = malloc(l + 1);
  IDRIS2RC2_VERIFY(it->str, "malloc failed");
  memcpy(it->str, str, l + 1);
  it->pos = 0;
  return (IDRIS2RC2_Value *)idris2rc2_mkGCPointer(
      it, idris2rc2_mkClosure((IDRIS2RC2_Value * (*)()) onCollectStringIterator, 2, 0));
}

IDRIS2RC2_Value *onCollectStringIterator(IDRIS2RC2_Value *ptr, void *unused) {
  IDRIS2RC2_StringIter *it = (IDRIS2RC2_StringIter *)((IDRIS2RC2_Pointer *)ptr)->p;
  free(it->str);
  free(it);
  return NULL;
}

IDRIS2RC2_Value *stringIteratorToString(void *a, char *str, IDRIS2RC2_Value *it_p, IDRIS2RC2_Closure *f) {
  IDRIS2RC2_StringIter *it = ((IDRIS2RC2_GCPointer *)it_p)->p->p;
  IDRIS2RC2_Value *strVal = (IDRIS2RC2_Value *)idris2rc2_mkString(it->str + it->pos);
  return idris2rc2_applyClosure(idris2rc2_dup((IDRIS2RC2_Value *)f), strVal);
}

IDRIS2RC2_Value *stringIteratorNext(char *s, IDRIS2RC2_Value *it_p) {
  IDRIS2RC2_StringIter *it = (IDRIS2RC2_StringIter *)((IDRIS2RC2_GCPointer *)it_p)->p->p;
  char c = it->str[it->pos];
  if (c == '\0')
    return NULL;
  it->pos++;
  IDRIS2RC2_Constructor *r = idris2rc2_newConstructor(2, 1);
  r->args[0] = idris2rc2_mkChar((unsigned char)c);
  r->args[1] = idris2rc2_dup(it_p);
  return (IDRIS2RC2_Value *)r;
}
