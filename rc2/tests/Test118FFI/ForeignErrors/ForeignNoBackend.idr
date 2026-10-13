module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Must fail to compile with the message in ForeignNoBackend.err (checked by
-- ../check.sh); never imported by Test118FFI.

-- Only a Scheme implementation: there is nothing rc2 can call.
%foreign "scheme:blodwen-thing"
prim__thing : Int -> Int

main : IO ()
main = printLn (prim__thing 1)
