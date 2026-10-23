module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Must fail to compile with the message in BadLibHint.err (checked by
-- ../check.sh); never imported by Test118FFI.

%foreign "CExpr:O_CREAT,libc 6$,fcntl.h"
prim__bad : Int

main : IO ()
main = printLn prim__bad
