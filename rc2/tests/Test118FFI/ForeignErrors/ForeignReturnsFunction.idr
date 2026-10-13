module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Must fail to compile with the message in ForeignReturnsFunction.err (checked by
-- ../check.sh); never imported by Test118FFI.

%foreign "C:make_adder,libc,adder.h"
prim__makeAdder : Int -> PrimIO (Int -> Int)

main : IO ()
main = do
  f <- primIO (prim__makeAdder 1)
  printLn (f 2)
