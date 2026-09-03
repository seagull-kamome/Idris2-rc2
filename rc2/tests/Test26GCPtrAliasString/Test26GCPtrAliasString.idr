module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test: a %foreign function returning a String that
-- aliases (no copy) memory owned by its own GCAnyPtr argument must
-- not have that memory freed by the arg's own drop before the string
-- is packed -- see createCFunctions' own packCFType-before-drop
-- ordering in Compiler.RC2.Emit. Also covers a related packCFType
-- regression (formerly a separate Test29GCAnyPtrReturn.idr, merged in
-- below): a %foreign function returning GCAnyPtr must pack the return
-- value into a real IDRIS2RC2_GCPointer (via idris2rc2_mkGCPointer),
-- not a plain IDRIS2RC2_Pointer (via idris2rc2_mkPointer) --
-- extractValue's own CFGCPtr case reads a GCAnyPtr argument back via a
-- GCPointer-shaped double indirection ((IDRIS2RC2_GCPointer*)v)->p->p,
-- so packCFType's CFGCPtr case must produce that exact shape. See
-- Compiler.RC2.Emit's packCFType/extractValue CFGCPtr cases.

%foreign "C:idris2rc2_test26_alloc,libc,Test26GCPtrAliasString.h"
prim__alloc : PrimIO AnyPtr

%foreign "C:idris2rc2_test26_free,libc,Test26GCPtrAliasString.h"
prim__free : AnyPtr -> PrimIO ()

%foreign "C:idris2rc2_test26_read_str,libc,Test26GCPtrAliasString.h"
prim__readStr : GCAnyPtr -> PrimIO String

%foreign "C:idris2rc2_test29_alloc,libc,Test26GCPtrAliasString.h"
prim__test29Alloc : PrimIO GCAnyPtr

%foreign "C:idris2rc2_test29_read,libc,Test26GCPtrAliasString.h"
prim__test29Read : GCAnyPtr -> PrimIO Int

%foreign "C:idris2rc2_test29_free,libc,Test26GCPtrAliasString.h"
prim__test29Free : GCAnyPtr -> PrimIO ()

main : IO ()
main = do
  raw <- primIO prim__alloc
  gcptr <- onCollectAny raw (\p => primIO (prim__free p))
  s <- primIO (prim__readStr gcptr)
  putStrLn s
  -- absorbed from former Test29GCAnyPtrReturn
  p <- primIO prim__test29Alloc
  v <- primIO (prim__test29Read p)
  printLn v
  primIO (prim__test29Free p)
