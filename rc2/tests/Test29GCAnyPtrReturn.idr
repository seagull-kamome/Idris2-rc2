module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test: a %foreign function returning GCAnyPtr must pack
-- the return value into a real IDRIS2RC2_GCPointer (via
-- idris2rc2_mkGCPointer), not a plain IDRIS2RC2_Pointer (via
-- idris2rc2_mkPointer) -- extractValue's own CFGCPtr case reads a
-- GCAnyPtr argument back via a GCPointer-shaped double indirection
-- ((IDRIS2RC2_GCPointer*)v)->p->p, so packCFType's CFGCPtr case must
-- produce that exact shape. See Compiler.RC2.Emit's packCFType/
-- extractValue CFGCPtr cases.

%foreign "C:idris2rc2_test29_alloc,libc,Test29GCAnyPtrReturn.h"
prim__alloc : PrimIO GCAnyPtr

%foreign "C:idris2rc2_test29_read,libc,Test29GCAnyPtrReturn.h"
prim__read : GCAnyPtr -> PrimIO Int

%foreign "C:idris2rc2_test29_free,libc,Test29GCAnyPtrReturn.h"
prim__free : GCAnyPtr -> PrimIO ()

main : IO ()
main = do
  p <- primIO prim__alloc
  v <- primIO (prim__read p)
  printLn v
  primIO (prim__free p)
