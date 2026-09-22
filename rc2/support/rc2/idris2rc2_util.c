#include "util.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

void idris2rc2_verify_failed(const char *file, int line, const char *cond,
                        const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  char message[1000];
  vsnprintf(message, sizeof(message), fmt, ap);
  va_end(ap);
  fprintf(stderr, "idris2rc2: assertion failed at %s:%d: %s: %s\n", file, line,
          cond, message);
  abort();
}
