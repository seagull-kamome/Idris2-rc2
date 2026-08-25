#include "concurrency_util.h"

void *idris2rc2_mutex_make(void) {
  IDRIS2RC2_Value *v = idris2rc2_alloc(sizeof(IDRIS2RC2_Mutex));
  v->header.tag = IDRIS2RC2_TAG_MUTEX;
  pthread_mutex_init(&((IDRIS2RC2_Mutex *)v)->mutex, NULL);
  return v;
}

void idris2rc2_mutex_acquire(IDRIS2RC2_Value *mutex) {
  pthread_mutex_lock(&((IDRIS2RC2_Mutex *)mutex)->mutex);
}

void idris2rc2_mutex_release(IDRIS2RC2_Value *mutex) {
  pthread_mutex_unlock(&((IDRIS2RC2_Mutex *)mutex)->mutex);
}

void *idris2rc2_condition_make(void) {
  IDRIS2RC2_Value *v = idris2rc2_alloc(sizeof(IDRIS2RC2_Condition));
  v->header.tag = IDRIS2RC2_TAG_CONDITION;
  pthread_cond_init(&((IDRIS2RC2_Condition *)v)->cond, NULL);
  return v;
}

void idris2rc2_condition_wait(IDRIS2RC2_Value *cond, IDRIS2RC2_Value *mutex) {
  pthread_cond_wait(&((IDRIS2RC2_Condition *)cond)->cond, &((IDRIS2RC2_Mutex *)mutex)->mutex);
}

void idris2rc2_condition_signal(IDRIS2RC2_Value *cond) {
  pthread_cond_signal(&((IDRIS2RC2_Condition *)cond)->cond);
}

void idris2rc2_condition_broadcast(IDRIS2RC2_Value *cond) {
  pthread_cond_broadcast(&((IDRIS2RC2_Condition *)cond)->cond);
}
