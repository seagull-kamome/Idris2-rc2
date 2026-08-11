#pragma once

#include <stdnoreturn.h>

#define IDRIS2RC2_VERIFY(cond, ...)                                                \
  do {                                                                       \
    if (!(cond)) {                                                           \
      idris2rc2_verify_failed(__FILE__, __LINE__, #cond, __VA_ARGS__);             \
    }                                                                        \
  } while (0)

noreturn void idris2rc2_verify_failed(const char *file, int line, const char *cond,
                                 const char *fmt, ...)
#if defined(__clang__) || defined(__GNUC__)
    __attribute__((format(printf, 4, 5)))
#endif
    ;
