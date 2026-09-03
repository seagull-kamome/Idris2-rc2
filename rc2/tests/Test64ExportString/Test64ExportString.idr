module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for `%export`'s CFString return support (rc2/doc/
-- export-support.md) -- pins down the exact bug the naive generic
-- extractValue-then-drop-then-return path would have (extractValue's
-- own CFString case aliases the Boxed value's own malloc'd buffer, so
-- dropping it before returning would hand the C caller a dangling
-- pointer): `greet` is called ordinarily from Idris (`main`) and from
-- plain C (companion Test64ExportString.c), which explicitly `free()`s
-- the returned buffer itself, proving the wrapper's own independent-
-- copy contract. Leak/UAF-sensitive by design -- registered in
-- verify.sh's LEAK_SENSITIVE_TESTS.

%export "C:idris2rc2_test64_greet"
greet : Int -> String
greet n = "hello " ++ show n

%foreign "C:idris2rc2_test64_run_check,libc,Test64ExportString.h"
prim__runCheck : PrimIO Int

main : IO ()
main = do
  putStrLn (greet 7)
  r <- primIO prim__runCheck
  printLn r
