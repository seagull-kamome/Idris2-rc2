module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for `%cg rc2 extraRuntime=<path>` (Compiler.RC2.RC2):
-- splices the referenced C file's contents directly into the
-- generated .c, right after its own #includes -- see the README's own
-- "%cg rc2 directives" section. Test31CgExtraRuntimeSupport.c defines
-- a plain C function with no Idris-side header/lib wiring at all; the
-- bare (no lib/header field) %foreign declaration below calls it
-- directly, relying purely on textual order in the single generated
-- translation unit -- no separate .a/.o, no IDRIS2_CFLAGS/IDRIS2_LDFLAGS
-- plumbing (contrast with libs/idris2-Text's own README).
--
-- Named Test31CgExtraRuntimeSupport.c, not Test31CgExtraRuntime.c, so
-- verify.sh's own $name.c companion-object auto-link mechanism (a
-- *different* way to bring in outside C, see e.g. Test29GCAnyPtrReturn)
-- doesn't also pick it up and link it in as a second definition of the
-- same symbol.

%cg rc2 extraRuntime=Test31CgExtraRuntimeSupport.c

%foreign "C:idris2rc2_test31_extra_double"
prim__extraDouble : Int -> PrimIO Int

main : IO ()
main = printLn !(primIO (prim__extraDouble 21))
