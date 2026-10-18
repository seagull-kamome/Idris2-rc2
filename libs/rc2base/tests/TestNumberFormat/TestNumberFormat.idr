module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Exercises Text.NumberFormat: the basic nibble -> char `digit`, and a
-- `ToHex` instance for every fixed-width integer type. The format is
-- fixed width, zero-padded, lowercase, and two's-complement for the
-- signed types, so the strings checked here are the specification, not
-- just samples. Pure formatting, so the output is backend-independent.

import Data.Bits
import Text.NumberFormat

p : String -> String -> IO ()
p label value = putStrLn (label ++ " = " ++ value)

main : IO ()
main = do
  putStrLn "--- digit ---"
  putStrLn ("0..15 = " ++ pack (map digit
    (the (List Bits8) [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15])))

  putStrLn "--- Bits8 ---"
  p "0x00" (toHex (the Bits8 0x00))
  p "0x0a" (toHex (the Bits8 0x0a))
  p "0x0f" (toHex (the Bits8 0x0f))
  p "0x10" (toHex (the Bits8 0x10))
  p "0x7f" (toHex (the Bits8 0x7f))
  p "0x80" (toHex (the Bits8 0x80))
  p "0xff" (toHex (the Bits8 0xff))

  putStrLn "--- Bits16 ---"
  p "0x0000" (toHex (the Bits16 0x0000))
  p "0x1234" (toHex (the Bits16 0x1234))
  p "0xabcd" (toHex (the Bits16 0xabcd))
  p "0xffff" (toHex (the Bits16 0xffff))

  putStrLn "--- Bits32 ---"
  p "0x00000000" (toHex (the Bits32 0x00000000))
  p "0x12345678" (toHex (the Bits32 0x12345678))
  p "0xdeadbeef" (toHex (the Bits32 0xdeadbeef))
  p "0xffffffff" (toHex (the Bits32 0xffffffff))

  putStrLn "--- Bits64 ---"
  p "0x0000000000000000" (toHex (the Bits64 0x0000000000000000))
  p "0x0123456789abcdef" (toHex (the Bits64 0x0123456789abcdef))
  p "0xffffffffffffffff" (toHex (the Bits64 0xffffffffffffffff))

  putStrLn "--- Int8 ---"
  p "0"      (toHex (the Int8 0))
  p "1"      (toHex (the Int8 1))
  p "127"    (toHex (the Int8 127))
  p "-1"     (toHex (the Int8 (-1)))
  p "-2"     (toHex (the Int8 (-2)))
  p "-128"   (toHex (the Int8 (-128)))

  putStrLn "--- Int16 ---"
  p "0"      (toHex (the Int16 0))
  p "1"      (toHex (the Int16 1))
  p "32767"  (toHex (the Int16 32767))
  p "-1"     (toHex (the Int16 (-1)))
  p "-32768" (toHex (the Int16 (-32768)))

  putStrLn "--- Int32 ---"
  p "0"       (toHex (the Int32 0))
  p "1"       (toHex (the Int32 1))
  p "2147483647" (toHex (the Int32 2147483647))
  p "-1"      (toHex (the Int32 (-1)))
  p "-2147483648" (toHex (the Int32 (-2147483647 - 1)))

  putStrLn "--- Int64 ---"
  p "0"     (toHex (the Int64 0))
  p "1"     (toHex (the Int64 1))
  p "-1"    (toHex (the Int64 (-1)))
  p "-256"  (toHex (the Int64 (-256)))

  putStrLn "--- Int ---"
  p "0"     (toHex (the Int 0))
  p "1"     (toHex (the Int 1))
  p "255"   (toHex (the Int 255))
  p "-1"    (toHex (the Int (-1)))
  p "-256"  (toHex (the Int (-256)))

  putStrLn "--- done ---"
