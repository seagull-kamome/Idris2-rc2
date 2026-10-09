module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Must fail to compile with the message in RNotInteger.err (checked by
-- ../check.sh); never imported by Test118FFI.

%foreign "CExpr:mpz_set_si($r, $1),libgmp,gmp.h"
prim__bad : Int -> Int

main : IO ()
main = printLn (prim__bad 1)
