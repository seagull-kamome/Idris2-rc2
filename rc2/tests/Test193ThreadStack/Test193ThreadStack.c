// Companion C for Test193ThreadStack.
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "Test193ThreadStack.h"

#include <pthread.h>

int64_t idris2rc2_test193_stackSize(void) {
#ifdef __GLIBC__
  pthread_attr_t attr;
  void *addr;
  size_t size = 0;
  if (pthread_getattr_np(pthread_self(), &attr) != 0) return 0;
  pthread_attr_getstack(&attr, &addr, &size);
  pthread_attr_destroy(&attr);
  return (int64_t)size;
#else
  return 0;
#endif
}
