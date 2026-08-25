#ifndef CONCURRENCY_UTIL_H
#define CONCURRENCY_UTIL_H

#include "rc2/datatypes.h"
#include "rc2/memory.h"

void *idris2rc2_mutex_make(void);
void idris2rc2_mutex_acquire(IDRIS2RC2_Value *mutex);
void idris2rc2_mutex_release(IDRIS2RC2_Value *mutex);

void *idris2rc2_condition_make(void);
void idris2rc2_condition_wait(IDRIS2RC2_Value *cond, IDRIS2RC2_Value *mutex);
void idris2rc2_condition_signal(IDRIS2RC2_Value *cond);
void idris2rc2_condition_broadcast(IDRIS2RC2_Value *cond);

#endif
