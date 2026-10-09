module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for System.FFI.C.Array: for each of the eleven
-- supported element types (Bits8/16/32/64, Int8/16/32/64, Int, Double,
-- AnyPtr), allocate a small CArray, store distinct values at every
-- index, and check fetch reads each one back correctly (also
-- exercising `length`). A twelfth check writes through an AnyPtr
-- element read back out of a CArray to confirm it really aliases the
-- pointer that was stored, not just an equally-non-null one.

import Data.Fin
import System.FFI
import System.FFI.C.Array
import System.FFI.C.Ptr

allFins : List (Fin 4)
allFins = [FZ, FS FZ, FS (FS FZ), FS (FS (FS FZ))]

main : IO ()
main = do
  arr8 <- newCArray {ty = Bits8} 4
  traverse_ (\i => store arr8 i (cast (finToNat i) + 10)) allFins
  vs8 <- traverse (fetch arr8) allFins
  printLn (vs8 == [10, 11, 12, 13])
  printLn (length arr8 == 4)

  arr16 <- newCArray {ty = Bits16} 4
  traverse_ (\i => store arr16 i (cast (finToNat i) + 1000)) allFins
  vs16 <- traverse (fetch arr16) allFins
  printLn (vs16 == [1000, 1001, 1002, 1003])

  arr32 <- newCArray {ty = Bits32} 4
  traverse_ (\i => store arr32 i (cast (finToNat i) + 100000)) allFins
  vs32 <- traverse (fetch arr32) allFins
  printLn (vs32 == [100000, 100001, 100002, 100003])

  arr64 <- newCArray {ty = Bits64} 4
  traverse_ (\i => store arr64 i (cast (finToNat i) + 0xfeedfacecafebeef)) allFins
  vs64 <- traverse (fetch arr64) allFins
  printLn (vs64 == [0xfeedfacecafebeef, 0xfeedfacecafebef0, 0xfeedfacecafebef1, 0xfeedfacecafebef2])

  arri8 <- newCArray {ty = Int8} 4
  traverse_ (\i => store arri8 i (cast (finToNat i) - 2)) allFins
  vsi8 <- traverse (fetch arri8) allFins
  printLn (vsi8 == [-2, -1, 0, 1])

  arri16 <- newCArray {ty = Int16} 4
  traverse_ (\i => store arri16 i (cast (finToNat i) - 12345)) allFins
  vsi16 <- traverse (fetch arri16) allFins
  printLn (vsi16 == [-12345, -12344, -12343, -12342])

  arri32 <- newCArray {ty = Int32} 4
  traverse_ (\i => store arri32 i (cast (finToNat i) - 1234567890)) allFins
  vsi32 <- traverse (fetch arri32) allFins
  printLn (vsi32 == [-1234567890, -1234567889, -1234567888, -1234567887])

  arri64 <- newCArray {ty = Int64} 4
  traverse_ (\i => store arri64 i (cast (finToNat i) - 9223372036854775808)) allFins
  vsi64 <- traverse (fetch arri64) allFins
  printLn (vsi64 == [-9223372036854775808, -9223372036854775807, -9223372036854775806, -9223372036854775805])

  arrInt <- newCArray {ty = Int} 4
  traverse_ (\i => store arrInt i (cast (finToNat i) + 1234567890123)) allFins
  vsInt <- traverse (fetch arrInt) allFins
  printLn (vsInt == [1234567890123, 1234567890124, 1234567890125, 1234567890126])

  arrD <- newCArray {ty = Double} 4
  traverse_ (\i => store arrD i (cast (finToNat i) + 0.5)) allFins
  vsD <- traverse (fetch arrD) allFins
  printLn (vsD == [0.5, 1.5, 2.5, 3.5])

  raw <- malloc 16
  arrP <- newCArray {ty = AnyPtr} 2
  store arrP FZ raw
  p0 <- fetch arrP FZ
  let bufP : Ptr Bits32
      bufP = prim__castPtr p0
  unsafePtrStore bufP 0 0xcafef00d
  let bufRaw : Ptr Bits32
      bufRaw = prim__castPtr raw
  v <- unsafePtrFetch bufRaw 0
  printLn (v == 0xcafef00d)
  free raw
