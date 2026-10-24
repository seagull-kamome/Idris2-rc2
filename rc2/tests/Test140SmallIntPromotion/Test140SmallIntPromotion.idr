module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Arithmetic on the integer types narrower than C's `int` (Int8, Int16, Bits8,
-- Bits16) wraps at the type's width. C promotes the operands to `int`, so a
-- native expression has to narrow its result again before a comparison, a
-- shift or a further operation reads it. The operands come from the command
-- line so that nothing is folded at compile time.

import System
import Data.Bits

%default total

main : IO ()
main = do
  args <- getArgs
  let n : Integer = cast (length args) - 1
  let i8 : Int8 = fromInteger (127 + n)
  let i16 : Int16 = fromInteger (32767 + n)
  let b8 : Bits8 = fromInteger (255 + n)
  let b16 : Bits16 = fromInteger (65535 + n)
  putStrLn ("Int8 add: " ++ show (i8 + 1 > 0) ++ " " ++ show (i8 + 1 == -128) ++ " " ++ show (i8 + 1))
  putStrLn ("Int8 sub: " ++ show (negate i8 - 2 > 0) ++ " " ++ show (negate i8 - 2 == 127))
  putStrLn ("Int8 mul: " ++ show (i8 * 2 == -2) ++ " " ++ show (i8 * i8 == 1))
  putStrLn ("Int8 neg: " ++ show (negate (i8 + 1) == -128))
  putStrLn ("Int16 add: " ++ show (i16 + 1 < 0) ++ " " ++ show (i16 + 1 == -32768))
  putStrLn ("Int16 mul: " ++ show (i16 * 2 == -2) ++ " " ++ show (i16 * i16 == 1))
  putStrLn ("Bits8 add: " ++ show (b8 + 1 == 0) ++ " " ++ show (b8 + 1 < 5))
  putStrLn ("Bits8 sub: " ++ show (0 - b8 == 1) ++ " " ++ show (b8 - 255 - 1 == 255))
  putStrLn ("Bits8 mul: " ++ show (b8 * b8 == 1) ++ " " ++ show (b8 * 2 == 254))
  putStrLn ("Bits8 shift: " ++ show (b8 `shiftL` 1 == 254) ++ " " ++ show ((b8 + 1) `shiftR` 7 == 0))
  putStrLn ("Bits8 bits: " ++ show (complement b8 == 0) ++ " " ++ show (((b8 + 1) .|. 0) == 0))
  putStrLn ("Bits16 add: " ++ show (b16 + 1 == 0) ++ " " ++ show (b16 + 1 < 5))
  putStrLn ("Bits16 mul: " ++ show (b16 * b16 == 1) ++ " " ++ show (b16 * 2 == 65534))
  putStrLn ("Bits16 sub: " ++ show (0 - b16 == 1))
  -- Int16 sub and neg, minBound, the arithmetic shift of the narrow signed types
  let lo8 : Int8 = fromInteger (-128 + n)
  let lo16 : Int16 = fromInteger (-32768 + n)
  putStrLn ("Int16 sub: " ++ show (negate i16 - 2 > 0) ++ " " ++ show (negate i16 - 2 == 32767) ++ " " ++ show (lo16 - 1 == 32767))
  putStrLn ("Int16 neg: " ++ show (negate lo16 == lo16) ++ " " ++ show (negate (i16 + 1) == lo16))
  putStrLn ("Int8 minBound: " ++ show (negate lo8 == lo8) ++ " " ++ show (lo8 - 1 == i8) ++ " " ++ show (lo8 * lo8 == 0))
  putStrLn ("Int8 shift: " ++ show (lo8 `shiftR` 7 == -1) ++ " " ++ show ((i8 + 1) `shiftR` 1 == -64))
  putStrLn ("Int16 shift: " ++ show (lo16 `shiftR` 15 == -1) ++ " " ++ show ((i16 + 1) `shiftR` 1 == -16384))
  putStrLn ("Bits16 mul wide: " ++ show ((b16 - 1) * (b16 - 1) == 4) ++ " " ++ show ((b16 - 255) * (b16 - 255) == 0))
