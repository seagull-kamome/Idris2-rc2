module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Must fail to compile with the message in UnterminatedString.err (checked by
-- ../check.sh); never imported by Test118FFI.

%foreign "CExpr:strlen(\"abc),libc,string.h"
prim__bad : Int32 -> Int32

main : IO ()
main = printLn (prim__bad 1)
