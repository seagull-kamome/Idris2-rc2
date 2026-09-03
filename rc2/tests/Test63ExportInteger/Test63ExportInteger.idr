module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for `%export`'s CFInteger support, both directions
-- (rc2/doc/export-support.md): `addInteger` is called ordinarily from
-- Idris (`main`, proving the wrapper is purely additive) and from
-- plain C (companion Test63ExportInteger.c) with `mpz_t` values built
-- directly via GMP, well outside Int's 64-bit range -- proving the
-- argument-side `idris2rc2_mkIntegerFromMpz` copy-in and the
-- return-side `mpz_t out`-parameter convention (mirroring
-- `%foreign`'s own established Integer-return shape, see
-- Test54FFIInteger) are both genuinely GMP-correct, not just
-- Int64-range-correct. Leak/UAF-sensitive by design -- registered in
-- verify.sh's LEAK_SENSITIVE_TESTS.

%export "C:idris2rc2_test63_add"
addInteger : Integer -> Integer -> Integer
addInteger x y = x + y

%foreign "C:idris2rc2_test63_run_check,libc,Test63ExportInteger.h"
prim__runCheck : PrimIO Int

main : IO ()
main = do
  printLn (addInteger 40 2)
  r <- primIO prim__runCheck
  printLn r
