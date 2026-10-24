module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- `minBound `div` (-1)` overflows: C traps it (SIGFPE) for the 32- and 64-bit
-- types. Idris wraps, so the quotient is `minBound` again and the remainder 0.
-- A divisor of `minBound` has no positive counterpart in its own type, so the
-- Euclidean remainder is computed without negating it. Checked on the native
-- path (operands from the command line, so nothing folds) and on the boxed path
-- (operands through the `Integral` dictionary).

import System

%default total

boxed : (Integral a, Neg a, Show a) => String -> a -> IO ()
boxed name lo = do
  let xs = [ (lo, negate 1), (lo + 1, negate 1), (lo, 1), (negate 5, lo), (5, lo), (lo, lo)
           , (lo + 1, lo), (7, negate 3), (negate 7, 3), (negate 7, negate 3), (negate 6, 3) ]
  putStrLn (name ++ " boxed div: " ++ show (map (\(a, b) => a `div` b) xs))
  putStrLn (name ++ " boxed mod: " ++ show (map (\(a, b) => a `mod` b) xs))

main : IO ()
main = do
  args <- getArgs
  let n : Integer = cast (length args) - 1
  let m1 : Int = cast n - 1
  let lo : Int = fromInteger (-9223372036854775808 + n)
  putStrLn ("Int div: " ++ show (lo `div` m1) ++ " " ++ show ((lo + 1) `div` m1))
  putStrLn ("Int mod: " ++ show (lo `mod` m1) ++ " " ++ show ((lo + 1) `mod` m1))
  let lo64 : Int64 = fromInteger (-9223372036854775808 + n)
  let m64 : Int64 = fromInteger (n - 1)
  putStrLn ("Int64 div: " ++ show (lo64 `div` m64) ++ " mod: " ++ show (lo64 `mod` m64))
  let lo32 : Int32 = fromInteger (-2147483648 + n)
  let m32 : Int32 = fromInteger (n - 1)
  putStrLn ("Int32 div: " ++ show (lo32 `div` m32) ++ " mod: " ++ show (lo32 `mod` m32))
  let lo16 : Int16 = fromInteger (-32768 + n)
  let m16 : Int16 = fromInteger (n - 1)
  putStrLn ("Int16 div: " ++ show (lo16 `div` m16) ++ " mod: " ++ show (lo16 `mod` m16))
  let lo8 : Int8 = fromInteger (-128 + n)
  let m8 : Int8 = fromInteger (n - 1)
  putStrLn ("Int8 div: " ++ show (lo8 `div` m8) ++ " mod: " ++ show (lo8 `mod` m8))
  -- a divisor of minBound, native
  let loI : Int = fromInteger (-9223372036854775808 + n)
  putStrLn ("Int by minBound: " ++ show (map (\a => (a `div` loI, a `mod` loI)) [-5 + cast n, 5 + cast n, loI, loI + 1]))
  let lo32b : Int32 = fromInteger (-2147483648 + n)
  putStrLn ("Int32 by minBound: " ++ show (map (\a => (a `div` lo32b, a `mod` lo32b)) [-5 + fromInteger n, 5 + fromInteger n, lo32b, lo32b + 1]))
  let lo16b : Int16 = fromInteger (-32768 + n)
  putStrLn ("Int16 by minBound: " ++ show (map (\a => (a `div` lo16b, a `mod` lo16b)) [-5 + fromInteger n, 5 + fromInteger n, lo16b, lo16b + 1]))
  let lo8b : Int8 = fromInteger (-128 + n)
  putStrLn ("Int8 by minBound: " ++ show (map (\a => (a `div` lo8b, a `mod` lo8b)) [-5 + fromInteger n, 5 + fromInteger n, lo8b, lo8b + 1]))
  boxed "Int" (fromInteger {ty = Int} (-9223372036854775808))
  boxed "Int64" (fromInteger {ty = Int64} (-9223372036854775808))
  boxed "Int32" (fromInteger {ty = Int32} (-2147483648))
  boxed "Int16" (fromInteger {ty = Int16} (-32768))
  boxed "Int8" (fromInteger {ty = Int8} (-128))
