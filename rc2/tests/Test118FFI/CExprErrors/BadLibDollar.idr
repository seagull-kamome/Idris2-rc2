module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- The shell syntax in the name is a no-op (`:`), so that nothing happens even if
-- the name were ever to reach a shell. Must fail to compile with the message in BadLibDollar.err (checked by
-- ../check.sh); never imported by Test118FFI.

%foreign "CExpr:O_CREAT,libc;libfoo$(:),fcntl.h"
prim__bad : Int

main : IO ()
main = printLn prim__bad
