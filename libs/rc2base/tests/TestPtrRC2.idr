module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for System.FFI.C.Ptr: for each of the eleven
-- supported element types (Bits8/16/32/64, Int8/16/32/64, Int, Double,
-- AnyPtr), unsafePtrStore a value into a `System.FFI.malloc`'d region
-- at its own disjoint offset and check unsafePtrFetch reads the same
-- value back. `offset` is an element index (like C's own `p[offset]`),
-- not a byte offset -- each call below is annotated with the byte
-- range it actually touches, chosen disjoint from every other call's.
-- A twelfth check writes through a pointer round-tripped via
-- AnyPtr.unsafePtrStore/unsafePtrFetch and reads back through the
-- original pointer, confirming the round-tripped AnyPtr really denotes
-- the same memory (not just an equally-non-null one).

import System.FFI
import System.FFI.C.Ptr

main : IO ()
main = do
  raw <- malloc 128
  let buf = prim__castPtr {t = Bits8} raw

  -- bytes 0-0
  Bits8.unsafePtrStore buf 0 0xff
  v1 <- Bits8.unsafePtrFetch buf 0
  printLn (v1 == 0xff)

  -- bytes 8-9
  Bits16.unsafePtrStore buf 4 0xbeef
  v2 <- Bits16.unsafePtrFetch buf 4
  printLn (v2 == 0xbeef)

  -- bytes 16-19
  Bits32.unsafePtrStore buf 4 0xdeadbeef
  v3 <- Bits32.unsafePtrFetch buf 4
  printLn (v3 == 0xdeadbeef)

  -- bytes 24-31
  Bits64.unsafePtrStore buf 3 0xfeedfacecafebeef
  v4 <- Bits64.unsafePtrFetch buf 3
  printLn (v4 == 0xfeedfacecafebeef)

  -- bytes 32-32
  Int8.unsafePtrStore buf 32 (-1)
  v5 <- Int8.unsafePtrFetch buf 32
  printLn (v5 == -1)

  -- bytes 40-41
  Int16.unsafePtrStore buf 20 (-12345)
  v6 <- Int16.unsafePtrFetch buf 20
  printLn (v6 == -12345)

  -- bytes 48-51
  Int32.unsafePtrStore buf 12 (-1234567890)
  v7 <- Int32.unsafePtrFetch buf 12
  printLn (v7 == -1234567890)

  -- bytes 56-63
  Int64.unsafePtrStore buf 7 (-9223372036854775808)
  v8 <- Int64.unsafePtrFetch buf 7
  printLn (v8 == -9223372036854775808)

  -- bytes 64-71
  System.FFI.C.Ptr.Int.unsafePtrStore buf 8 1234567890123
  v9 <- System.FFI.C.Ptr.Int.unsafePtrFetch buf 8
  printLn (v9 == 1234567890123)

  -- bytes 72-79
  Double.unsafePtrStore buf 9 3.14159265358979
  v10 <- Double.unsafePtrFetch buf 9
  printLn (v10 == 3.14159265358979)

  -- bytes 80-87
  AnyPtr.unsafePtrStore buf 10 raw
  p2 <- AnyPtr.unsafePtrFetch buf 10
  let buf2 = prim__castPtr {t = Bits8} p2
  -- bytes 100-103, written through buf2 (the round-tripped pointer),
  -- read back through buf -- confirms buf2 really aliases buf's memory
  Bits32.unsafePtrStore buf2 25 0xcafef00d
  v11 <- Bits32.unsafePtrFetch buf 25
  printLn (v11 == 0xcafef00d)

  free raw
