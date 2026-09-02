module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for System.FFI.C.Ptr: for each of the eleven
-- supported element types (Bits8/16/32/64, Int8/16/32/64, Int, Double,
-- AnyPtr), unsafePtrStore a value into a `System.FFI.malloc`'d region
-- at its own disjoint offset and check unsafePtrFetch reads the same
-- value back -- dispatched via `PtrCFFI`'s own instance for each
-- `let`-bound pointer's element type, not a per-type namespace.
-- `offset` is an element index (like C's own `p[offset]`), not a byte
-- offset -- each call below is annotated with the byte range it
-- actually touches, chosen disjoint from every other call's.
-- A twelfth check writes through a pointer round-tripped via
-- unsafePtrStore/unsafePtrFetch at `AnyPtr`'s own instance and reads
-- back through the original pointer, confirming the round-tripped
-- AnyPtr really denotes the same memory (not just an equally-non-null
-- one).

import System.FFI
import System.FFI.C.Ptr

main : IO ()
main = do
  raw <- malloc 128

  -- bytes 0-0
  let buf8 : Ptr Bits8
      buf8 = prim__castPtr raw
  unsafePtrStore buf8 0 0xff
  v1 <- unsafePtrFetch buf8 0
  printLn (v1 == 0xff)

  -- bytes 8-9
  let buf16 : Ptr Bits16
      buf16 = prim__castPtr raw
  unsafePtrStore buf16 4 0xbeef
  v2 <- unsafePtrFetch buf16 4
  printLn (v2 == 0xbeef)

  -- bytes 16-19
  let buf32 : Ptr Bits32
      buf32 = prim__castPtr raw
  unsafePtrStore buf32 4 0xdeadbeef
  v3 <- unsafePtrFetch buf32 4
  printLn (v3 == 0xdeadbeef)

  -- bytes 24-31
  let buf64 : Ptr Bits64
      buf64 = prim__castPtr raw
  unsafePtrStore buf64 3 0xfeedfacecafebeef
  v4 <- unsafePtrFetch buf64 3
  printLn (v4 == 0xfeedfacecafebeef)

  -- bytes 32-32
  let bufI8 : Ptr Int8
      bufI8 = prim__castPtr raw
  unsafePtrStore bufI8 32 (-1)
  v5 <- unsafePtrFetch bufI8 32
  printLn (v5 == -1)

  -- bytes 40-41
  let bufI16 : Ptr Int16
      bufI16 = prim__castPtr raw
  unsafePtrStore bufI16 20 (-12345)
  v6 <- unsafePtrFetch bufI16 20
  printLn (v6 == -12345)

  -- bytes 48-51
  let bufI32 : Ptr Int32
      bufI32 = prim__castPtr raw
  unsafePtrStore bufI32 12 (-1234567890)
  v7 <- unsafePtrFetch bufI32 12
  printLn (v7 == -1234567890)

  -- bytes 56-63
  let bufI64 : Ptr Int64
      bufI64 = prim__castPtr raw
  unsafePtrStore bufI64 7 (-9223372036854775808)
  v8 <- unsafePtrFetch bufI64 7
  printLn (v8 == -9223372036854775808)

  -- bytes 64-71
  let bufInt : Ptr Int
      bufInt = prim__castPtr raw
  unsafePtrStore bufInt 8 1234567890123
  v9 <- unsafePtrFetch bufInt 8
  printLn (v9 == 1234567890123)

  -- bytes 72-79
  let bufD : Ptr Double
      bufD = prim__castPtr raw
  unsafePtrStore bufD 9 3.14159265358979
  v10 <- unsafePtrFetch bufD 9
  printLn (v10 == 3.14159265358979)

  -- bytes 80-87
  let bufP : Ptr AnyPtr
      bufP = prim__castPtr raw
  unsafePtrStore bufP 10 raw
  p2 <- unsafePtrFetch bufP 10
  let buf32' : Ptr Bits32
      buf32' = prim__castPtr p2
  -- bytes 100-103, written through buf32' (the round-tripped pointer),
  -- read back through buf32 -- confirms buf32' really aliases buf32's
  -- memory
  unsafePtrStore buf32' 25 0xcafef00d
  v11 <- unsafePtrFetch buf32 25
  printLn (v11 == 0xcafef00d)

  free raw
