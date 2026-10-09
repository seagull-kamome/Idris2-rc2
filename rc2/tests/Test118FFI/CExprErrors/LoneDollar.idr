module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Must fail to compile with the message in LoneDollar.err (checked by
-- ../check.sh); never imported by Test118FFI.

%foreign "CExpr:$x"
prim__bad : Int -> Int

main : IO ()
main = printLn (prim__bad 1)
