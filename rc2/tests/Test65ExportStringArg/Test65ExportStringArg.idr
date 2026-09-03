module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for `%export`'s CFString ARGUMENT support (rc2/doc/
-- export-support.md) -- the companion argument-direction to
-- Test64ExportString's own return-direction coverage. `packCFType`'s
-- own CFString case (`idris2rc2_mkString`) already copies the incoming
-- `char *` into a freshly Idris-owned buffer, so this is expected to be
-- safe with no wrapper special-casing -- this test exists to actually
-- pin that down, not just claim it: `strLen` is called ordinarily from
-- Idris (`main`) and from plain C (companion Test65ExportStringArg.c)
-- passing a plain string literal (never Idris/rc2-managed memory) that
-- the C side keeps using, unmodified, after the call returns, proving
-- rc2 never aliases or takes ownership of the caller's own buffer.

%export "C:idris2rc2_test65_strlen"
strLen : String -> Int
strLen s = cast (length s)

%foreign "C:idris2rc2_test65_run_check,libc,Test65ExportStringArg.h"
prim__runCheck : PrimIO Int

main : IO ()
main = do
  printLn (strLen "hello!")
  r <- primIO prim__runCheck
  printLn r
