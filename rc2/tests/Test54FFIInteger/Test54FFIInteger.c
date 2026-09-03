// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

// Companion C implementation for Test54FFIInteger.idr's own %foreign
// declaration.

#include "Test54FFIInteger.h"

// Thread-local fixed buffer, same leak-avoidance pattern as
// support/rc2/idris_net.c's own idrnet_addrToString -- packCFType's
// own idris2rc2_mkString always copies this immediately, so there is
// nothing to free either way, unlike returning a fresh mpz_get_str
// malloc(NULL, ...) allocation would be. Sized generously past this
// test's own 30-digit value plus a sign and NUL.
static _Thread_local char buf[256];

char *idris2rc2_test54_toDecimalString(mpz_t x) {
    mpz_get_str(buf, 10, x);
    return buf;
}

// idris2rc2_test55_* absorbed from former Test55FFIIntegerReturn.c.
// `result` is always a fresh, already-`mpz_init`'d mpz_t the Idris
// side allocated -- see Compiler.RC2.EmitUtil's own packCFType
// CFInteger case.

void idris2rc2_test55_fromDecimalString(mpz_t result, const char *s) {
    mpz_set_str(result, s, 10);
}

void idris2rc2_test55_fromDecimalStringIO(mpz_t result, const char *s) {
    mpz_set_str(result, s, 10);
}

void idris2rc2_test55_addInt(mpz_t result, mpz_t x, int64_t y) {
    mpz_add_ui(result, x, (unsigned long)y);
}

void idris2rc2_test55_addIntIO(mpz_t result, mpz_t x, int64_t y) {
    mpz_add_ui(result, x, (unsigned long)y);
}
