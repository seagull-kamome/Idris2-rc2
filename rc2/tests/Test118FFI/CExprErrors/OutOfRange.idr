module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Must fail to compile with the message in OutOfRange.err (checked by
-- ../check.sh); never imported by Test118FFI.

%foreign "CExpr:($1) + ($3),libc"
prim__bad : Int -> Int -> Int

main : IO ()
main = printLn (prim__bad 1 2)
