// A C host of the libraries: what they export, through the generated headers.
#include <gmp.h>
#include <stdio.h>
#include <stdlib.h>

#include "idris2rc2_runtime.h"
#include "addlib.h"
#include "add2lib.h"

int main(void) {
  idris2rc2_rtInit();
  printf("%ld %ld\n", (long)libadd_two(10, 32), (long)lib2_add_two(1, 2));
  char *g = libgreet("world");
  char *h = lib2_greet("world");
  printf("%s / %s\n", g, h);
  free(g);
  free(h);
  mpz_t a, b, r;
  mpz_init_set_ui(a, 12345678901UL);
  mpz_init_set_ui(b, 1000000UL);
  libtotal(r, a, b);
  gmp_printf("%Zd\n", r);
  mpz_clear(r);
  mpz_clear(a);
  mpz_clear(b);
  idris2rc2_rtFinish();
  return 0;
}
