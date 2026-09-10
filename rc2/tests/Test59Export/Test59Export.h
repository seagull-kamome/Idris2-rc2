// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

// Companion header for the merged %export suite Test59Export.idr.
// Every `extern` below is an rc2-generated %export wrapper
// (Compiler.RC2.Emit's emitExportWrapper), NOT defined in the
// companion .c -- declaring them `extern` here is exactly what a real
// external C caller of an %export'd Idris function would do. The
// non-`extern` prototypes are the companion .c's own driver functions,
// called back into Idris via %foreign.

#include <gmp.h>
#include <stdint.h>

// ---- section 1: scalars ----
extern int64_t idris2rc2_test_add(int64_t, int64_t);
extern double idris2rc2_test_scale(double, double);
int64_t idris2rc2_test_call_exports_from_c(int64_t seed);

// ---- section 2: CFPtr ----
// (an external C caller declares this `extern` itself, exactly as here)
extern void *idris2rc2_test60_identity(void *p);
int64_t idris2rc2_test60_run_check(void);

// ---- section 3: CFStruct ----
// void*-typed on purpose, same reasoning as Test24CStructSupport.h:
// rc2's own generated C already typedefs "test_point" itself
// (Compiler.RC2.Emit's StructDefs, populated from the %foreign
// make/free declarations) -- declaring the same struct shape again
// here would trip a duplicate-typedef error once both are visible in
// the same translation unit.
void *idris2rc2_test61_make_point(int64_t x, double y);
void idris2rc2_test61_free_point(void *p);
int64_t idris2rc2_test61_run_check(void);
extern int64_t idris2rc2_test61_get_x(void *p);
extern void *idris2rc2_test61_scale_point(void *p);

// ---- section 4: CFGCPtr argument ----
int64_t idris2rc2_test62_peek_byte(void *p);
int64_t idris2rc2_test62_run_check(void);
extern int64_t idris2rc2_test62_read_byte(void *p);

// ---- section 5: CFInteger ----
// `out` (the Integer return value's own out-parameter) is the *first*
// parameter, matching GMP's own convention (see Test54FFIInteger.h).
extern void idris2rc2_test63_add(mpz_t out, mpz_t x, mpz_t y);
int64_t idris2rc2_test63_run_check(void);

// ---- section 6: CFString return ----
// a plain, independently-allocated `char *` buffer, not an
// IDRIS2RC2_String and not const -- the caller owns it and must
// free() it themselves; never pass it to any idris2rc2_* function.
extern char *idris2rc2_test64_greet(int64_t n);
int64_t idris2rc2_test64_run_check(void);

// ---- section 7: CFString argument ----
// takes a plain `const char *`; rc2 copies it into its own
// Idris-owned buffer (idris2rc2_mkString) before use, so the caller's
// own string is never aliased or freed by rc2 and remains
// valid/unmodified after the call.
extern int64_t idris2rc2_test65_strlen(const char *s);
int64_t idris2rc2_test65_run_check(void);
