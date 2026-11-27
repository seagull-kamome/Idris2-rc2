// idris2rc2_crashC: what an RCrash lowers to (see idris2rc2_rt.h).

#include <stdio.h>
#include <stdlib.h>

#include "idris2rc2_rt.h"

void idris2rc2_crashC(const char *msg) {
  fprintf(stderr, "ERROR: %s\n", msg);
  exit(1);
}
