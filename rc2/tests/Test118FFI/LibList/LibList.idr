module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- The library field of a `%foreign` names several libraries separated by `;`
-- (rc2/doc/ffi-cexpr.md): each distinct name becomes one `-l` flag of the link
-- command. Built and run by ../check.sh with `--directive dumpcc`; the stub
-- libraries libdl and librt exist in every glibc.

%foreign "CExpr:labs($1),libc;libdl; librt;,stdlib.h"
prim__abs : Int -> Int

%foreign "CExpr:labs($1),libdl;libm,stdlib.h"
prim__labs : Int -> Int

main : IO ()
main = printLn (prim__abs (-5), prim__labs (-7))
