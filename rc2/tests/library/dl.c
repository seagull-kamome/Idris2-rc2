// A host that has the runtime and loads a library when it runs.
#include <dlfcn.h>
#include <stdio.h>

#include "idris2rc2_runtime.h"

int main(int argc, char **argv) {
  idris2rc2_rtInit();
  void *h = dlopen(argv[1], RTLD_NOW);
  if (!h) { fprintf(stderr, "%s\n", dlerror()); return 1; }
  long (*add)(long, long) = (long (*)(long, long))dlsym(h, "libadd_two");
  printf("%ld\n", add(1, 2));
  idris2rc2_rtFinish();
  return 0;
}
