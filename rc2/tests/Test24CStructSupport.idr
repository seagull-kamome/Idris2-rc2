module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Exercises System.FFI's getField/setField -- Compiler.RC2.RC's own
-- dedicated RStructGet/RStructSet nodes (rc2/doc/c-struct-support.md)
-- -- against a real C struct declared via a companion C file
-- (Test24CStructSupport.c/.h), the same way an actual C library
-- binding would establish a struct name. Reads a field twice in a row
-- (structVar used more than once), writes then rereads a field, and
-- reuses a setField call's own value operand three more times
-- afterward -- each exercising dropIfLastUse's own occurrence-order
-- ownership handling (Compiler.RC2.RC: never dup, drop only on an
-- operand's own last use) on both RStructGet and RStructSet.

import System.FFI

Point : Type
Point = Struct "test_point" [("x", Int), ("y", Double)]

%foreign "C:idris2rc2_test24_make_point,libc,Test24CStructSupport.h"
prim__makePoint : Int -> Double -> PrimIO Point

%foreign "C:idris2rc2_test24_free_point,libc,Test24CStructSupport.h"
prim__freePoint : Point -> PrimIO ()

getX : Point -> Int
getX p = getField p "x"

getY : Point -> Double
getY p = getField p "y"

setX : HasIO io => Point -> Int -> io ()
setX p v = liftIO (setField p "x" v)

setY : HasIO io => Point -> Double -> io ()
setY p v = liftIO (setField p "y" v)

main : IO ()
main = do
  p <- primIO (prim__makePoint 3 4.5)
  printLn (getX p)
  printLn (getY p)
  setY p 9.0
  printLn (getY p)
  -- structVar (p) read twice in a row: no dup should be needed either time.
  printLn (getX p + getX p)
  -- setField's own value operand reused after the call.
  let v : Int = the Int 40 + 2
  setX p v
  printLn (getX p)
  printLn v
  printLn (v + v)
  primIO (prim__freePoint p)
