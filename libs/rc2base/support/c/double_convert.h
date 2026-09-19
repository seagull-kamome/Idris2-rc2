#ifndef RC2BASE_DOUBLE_CONVERT_H
#define RC2BASE_DOUBLE_CONVERT_H

#include "rc2/datatypes.h"
#include "rc2/memory.h"

// Data.Double.Convert's native side: an opt-in, branch-free fast path
// for Double<->String, sitting next to (never replacing) rc2's own
// always-correct but GMP-per-call `cast`. See this directory's own
// double_convert.c for the full design writeup and
// libs/rc2base/README.md's "Data.Double.Convert" section for the
// user-facing summary.
//
// Both entry points are pure (no allocation beyond a fixed local
// buffer for the formatter, no global state) and always agree with
// rc2's own `cast {to=Double}` / `cast {to=String}` -- the fast path
// either produces the exact same double as `idris2rc2_parse_double`,
// or the exact same shortest-round-trip string as
// `idris2rc2_shortest_double`, or defers outright to whichever of
// those exact functions it wasn't confident about.

double idris2rc2_fastParseDouble(const char *s);

// Builds a fully-formed, correctly refcounted/tagged IDRIS2RC2_String
// directly (via idris2rc2_mkEmptyString), the same technique
// string_rc2.c's own idris2rc2_string_byte_slice and text_util.c's
// idris2rc2_TextBuffer_to_string use -- one allocation instead of
// formatting into a scratch buffer and letting a plain `String`-typed
// `%foreign` return copy it a second time via idris2rc2_mkString.
// Data.Double.Convert.idr's own Idris-side declares this as an
// unrecognized (CFUser) type, not `String`, so rc2's FFI marshaller
// passes the Boxed Value* through untouched instead of re-wrapping it.
IDRIS2RC2_Value *idris2rc2_fastShowDouble(double v);

#endif /* RC2BASE_DOUBLE_CONVERT_H */
