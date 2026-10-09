module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Must fail to compile with the message in BadHeaderAngle.err (checked by
-- ../check.sh); never imported by Test118FFI.

%foreign "CExpr:O_CREAT,libc,fcntl.h;<sys/stat.h>"
prim__bad : Int

main : IO ()
main = printLn prim__bad
