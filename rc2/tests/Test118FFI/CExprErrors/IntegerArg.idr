module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Must fail to compile with the message in IntegerArg.err (checked by
-- ../check.sh); never imported by Test118FFI.

%foreign "CExpr:$1"
prim__bad : Integer -> Int

main : IO ()
main = printLn (prim__bad 1)
