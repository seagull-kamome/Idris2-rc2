module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for Data.Buffer.RC2's five %foreign_impl patches
-- (setInt8/getInt8/getInt16/setInt64/getInt64). Round-trips negative,
-- positive, and boundary values through each -- the read side is the
-- part worth distrusting, since every one of these C macros builds its
-- result via an unsigned getBufferUIntLE and relies on the generated
-- FFI wrapper's own return-typed local (int8_t/int16_t/int64_t) to do
-- the sign-reinterpreting narrowing conversion (see Data.Buffer.RC2's
-- own header comment). getInt16/getInt64 are additionally cross-checked
-- against bytes written by a writer this module does *not* patch
-- (setInt16, upstream's own already-"RefC:"-tagged declaration; and
-- setBits64, already C-supported independent of this module) so a
-- match confirms the new read side agrees with independently-trusted
-- writers, not just with its own paired write side.

import Data.Buffer
import Data.Buffer.RC2

main : IO ()
main = do
  Just buf <- newBuffer 32
    | Nothing => putStrLn "newBuffer failed"

  -- Int8
  setInt8 buf 0 (-1)
  getInt8 buf 0 >>= printLn
  setInt8 buf 0 (-128)
  getInt8 buf 0 >>= printLn
  setInt8 buf 0 127
  getInt8 buf 0 >>= printLn

  -- Int16: getInt16 read back against setInt16 (independently trusted)
  setInt16 buf 4 (-12345)
  getInt16 buf 4 >>= printLn
  setInt16 buf 4 32000
  getInt16 buf 4 >>= printLn

  -- Int64: round-trip through the new pair
  setInt64 buf 8 (-1)
  getInt64 buf 8 >>= printLn
  setInt64 buf 8 (-9223372036854775808)
  getInt64 buf 8 >>= printLn
  setInt64 buf 8 9223372036854775807
  getInt64 buf 8 >>= printLn

  -- getInt64 read back against setBits64 (independently trusted),
  -- same all-ones bit pattern reinterpreted as -1.
  setBits64 buf 16 0xffffffffffffffff
  getInt64 buf 16 >>= printLn
