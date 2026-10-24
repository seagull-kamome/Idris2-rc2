module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for System.FFI.C.Limits: checks every binding against
-- the value the LP64 Linux target must have, and checks that the `char`
-- limits match either `schar` or `uchar` (its signedness varies by target).

import System.FFI.C.Limits

main : IO ()
main = do
  putStrLn "--- Testing System.FFI.C.Limits ---"

  printLn (charBit == 8)
  printLn (scharMin == -128)
  printLn (scharMax == 127)
  printLn (ucharMax == 0xff)
  printLn ((charMin == -128 && charMax == 127) || (charMin == 0 && charMax == 255))
  printLn (mbLenMax >= 1)

  printLn (shrtMin == -32768)
  printLn (shrtMax == 32767)
  printLn (ushrtMax == 0xffff)

  printLn (intMin == -2147483648)
  printLn (intMax == 2147483647)
  printLn (uintMax == 0xffffffff)

  printLn (longMin == -9223372036854775808)
  printLn (longMax == 9223372036854775807)
  printLn (ulongMax == 0xffffffffffffffff)

  printLn (llongMin == longMin)
  printLn (llongMax == longMax)
  printLn (ullongMax == ulongMax)

  putStrLn "--- Tests finished ---"
