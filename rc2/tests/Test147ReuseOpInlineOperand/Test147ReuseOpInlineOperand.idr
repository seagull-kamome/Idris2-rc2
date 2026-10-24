module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- A boxed `Int`/`Int64`/`Bits64` outside the immediate range (rc2/doc/immediate-
-- ints.md) is read inline by `lo + 1` and then handed to a boxed `+ - * div mod`
-- that disposes of its own operands (rc2/doc/rop-reuse.md). The reference the
-- inline read owed on `lo` was dropped with the operands and leaked: valgrind
-- (this test is in LEAK_SENSITIVE_TESTS) must see no definitely lost bytes. The
-- values come from the command line, so nothing folds at compile time.

import System

%default total

main : IO ()
main = do
  args <- getArgs
  let n : Integer = cast (length args) - 1
  let m : Int = cast n - 1
  -- each line gets a value of its own: one used twice, once inline in `lo + 1`
  let lo1 : Int = fromInteger (-9223372036854775808 + n)
  let lo2 : Int = fromInteger (-9223372036854775807 + n)
  let lo3 : Int = fromInteger (-9223372036854775806 + n)
  let lo4 : Int = fromInteger (-9223372036854775805 + n)
  let lo5 : Int = fromInteger (-9223372036854775804 + n)
  putStrLn (show (lo1 `div` m) ++ " " ++ show ((lo1 + 1) `div` m))
  putStrLn (show (lo2 `mod` m) ++ " " ++ show ((lo2 + 1) `mod` m))
  putStrLn (show (lo3 * m) ++ " " ++ show ((lo3 + 1) * m))
  putStrLn (show (lo4 - m) ++ " " ++ show ((lo4 + 1) - m))
  putStrLn (show (lo5 + m) ++ " " ++ show ((lo5 + 1) + m))
  let m64 : Int64 = fromInteger (n - 1)
  let a1 : Int64 = fromInteger (-9223372036854775808 + n)
  let a2 : Int64 = fromInteger (-9223372036854775807 + n)
  let a3 : Int64 = fromInteger (-9223372036854775806 + n)
  putStrLn (show (a1 `div` m64) ++ " " ++ show ((a1 + 1) `div` m64))
  putStrLn (show (a2 `mod` m64) ++ " " ++ show ((a2 + 1) `mod` m64))
  putStrLn (show (a3 * m64) ++ " " ++ show ((a3 + 1) * m64))
  let mb : Bits64 = fromInteger (n + 3)
  let h1 : Bits64 = fromInteger (18446744073709551615 + n)
  let h2 : Bits64 = fromInteger (18446744073709551614 + n)
  let h3 : Bits64 = fromInteger (18446744073709551613 + n)
  putStrLn (show (h1 `div` mb) ++ " " ++ show ((h1 - 1) `div` mb))
  putStrLn (show (h2 `mod` mb) ++ " " ++ show ((h2 - 1) `mod` mb))
  putStrLn (show (h3 * mb) ++ " " ++ show ((h3 - 1) * mb))
