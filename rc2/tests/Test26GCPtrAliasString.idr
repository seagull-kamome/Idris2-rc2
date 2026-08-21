module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test: a %foreign function returning a String that
-- aliases (no copy) memory owned by its own GCAnyPtr argument must
-- not have that memory freed by the arg's own drop before the string
-- is packed -- see createCFunctions' own packCFType-before-drop
-- ordering in Compiler.RC2.Emit.

%foreign "C:idris2rc2_test26_alloc,libc,Test26GCPtrAliasString.h"
prim__alloc : PrimIO AnyPtr

%foreign "C:idris2rc2_test26_free,libc,Test26GCPtrAliasString.h"
prim__free : AnyPtr -> PrimIO ()

%foreign "C:idris2rc2_test26_read_str,libc,Test26GCPtrAliasString.h"
prim__readStr : GCAnyPtr -> PrimIO String

main : IO ()
main = do
  raw <- primIO prim__alloc
  gcptr <- onCollectAny raw (\p => primIO (prim__free p))
  s <- primIO (prim__readStr gcptr)
  putStrLn s
