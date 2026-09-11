module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for Emit.idr's RStructGet fix (KNOWN-BUGS.md's own
-- "Emit.idr's RStructGet was missing the same (IDRIS2RC2_Value*)
-- cast..." entry): unlike Test84CgExternStruct (Int/Double fields
-- only, which never needed the outer cast at all --
-- idris2rc2_mkInt64/mkDouble already return IDRIS2RC2_Value*
-- directly), this test's own "name" field is CFString
-- (idris2rc2_mkString returns IDRIS2RC2_String*) and "data" is CFPtr
-- (idris2rc2_mkPointer returns IDRIS2RC2_Pointer*) -- both needed the
-- missing outer cast, and "name"'s own `const char *` declaration in
-- the real header (Test85CgExternStructPtrField.h) additionally
-- needed the inner field-access cast to discard that `const` before
-- idris2rc2_mkString would even compile against it.
--
-- "data" is set (by this test's own companion .c) to the exact same
-- pointer as "name" -- reading it back through ptrToString
-- independently confirms the CFPtr cast produced the *correct* void*
-- value, not just something that compiles.

import Data.String.FFI
import System.FFI

%cg rc2 externStruct=wide_point

Point : Type
Point = Struct "wide_point" [("id", Int), ("name", String), ("data", AnyPtr)]

%foreign "C:idris2rc2_test85_make_point,libc,Test85CgExternStructPtrField.h"
prim__makePoint : Int -> String -> PrimIO Point

%foreign "C:idris2rc2_test85_free_point,libc,Test85CgExternStructPtrField.h"
prim__freePoint : Point -> PrimIO ()

getId : Point -> Int
getId p = getField p "id"

getName : Point -> String
getName p = getField p "name"

getData : Point -> AnyPtr
getData p = getField p "data"

main : IO ()
main = do
  p <- primIO (prim__makePoint 42 "hello")
  printLn (getId p)
  putStrLn (getName p)
  printLn (ptrToString (getData p))
  primIO (prim__freePoint p)
