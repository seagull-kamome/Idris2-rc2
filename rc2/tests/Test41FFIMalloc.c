// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

#include <stdint.h>

void idris2rc2_test41_poke_byte(void *p, int val) {
    ((unsigned char *)p)[0] = (unsigned char)val;
}

int idris2rc2_test41_peek_byte(void *p) {
    return ((unsigned char *)p)[0];
}
