#pragma once

// Single include for generated C code (mirrors RefC's runtime.h).

#include "buffer.h"
#include "clock.h"
#include "datatypes.h"
#include "ioprims.h"
#include "memory.h"
#include "numeric.h"
#include "runtime.h"
#include "idris2rc2_strings.h"
#include "util.h"

// Upstream's own idris_support.h (the shared libidris2_support.a's own
// header, included separately below whenever a %foreign declaration
// names it) declares no prototype at all for idris2_setenv/
// idris2_unsetenv, even though idris_support.c actually defines both --
// a real upstream header/implementation mismatch (harmless under real
// RefC's default build, which only warns on the resulting implicit
// declaration; a hard error under this project's own -Werror policy).
// Declared here, ahead of that #include, so this file always wins and
// the mismatch never reaches the compiler -- the two functions
// themselves are still the shared library's own, unmodified.
int idris2_setenv(const char *name, const char *value, int overwrite);
int idris2_unsetenv(const char *name);
