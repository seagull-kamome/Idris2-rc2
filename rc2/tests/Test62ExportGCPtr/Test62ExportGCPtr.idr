module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for `%export`'s CFGCPtr-as-argument support
-- (rc2/doc/export-support.md) -- argument position only, a GCPtr
-- return is rejected at compile time (Compiler.RC2.RC2.validateExport)
-- and not exercised here. The companion C constructs a plain,
-- Idris-unaware pointer and hands it straight to the exported wrapper,
-- proving `packCFType CFGCPtr`'s own `idris2rc2_mkGCPointer(raw,
-- NULL)` wrapping of a raw incoming pointer works with no special-
-- casing beyond what CFPtr already needed.

import System.FFI

%foreign "C:idris2rc2_test62_peek_byte,libc,Test62ExportGCPtr.h"
prim__peekByte : GCAnyPtr -> PrimIO Int

%export "C:idris2rc2_test62_read_byte"
readByteExport : GCAnyPtr -> PrimIO Int
readByteExport p = prim__peekByte p

%foreign "C:idris2rc2_test62_run_check,libc,Test62ExportGCPtr.h"
prim__runCheck : PrimIO Int

main : IO ()
main = do
  r <- primIO prim__runCheck
  printLn r
