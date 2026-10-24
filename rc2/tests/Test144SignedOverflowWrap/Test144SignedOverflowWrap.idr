module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- `+ - *` and `negate` on the signed fixed-width integers wrap at the type's
-- width. Signed overflow is undefined in C, so rc2 computes these in unsigned
-- arithmetic. Checked on the native path (operands from the command line, so
-- nothing folds) and on the boxed path (operands through the `Num` and `Neg`
-- dictionaries).

import System

%default total

boxed : (Num a, Neg a, Show a) => String -> a -> a -> IO ()
boxed name lo hi = do
  putStrLn (name ++ " boxed add: " ++ show [hi + 1, hi + hi, lo + lo, lo + (-1)])
  putStrLn (name ++ " boxed sub: " ++ show [lo - 1, lo - hi, hi - lo, 0 - lo])
  putStrLn (name ++ " boxed mul: " ++ show [hi * 2, hi * hi, lo * lo, lo * (-1), lo * 2, hi * lo])
  putStrLn (name ++ " boxed neg: " ++ show [negate lo, negate hi, negate (lo + 1)])

main : IO ()
main = do
  args <- getArgs
  let n : Integer = cast (length args) - 1
  let hiI : Int = fromInteger (9223372036854775807 + n)
  let loI : Int = fromInteger (-9223372036854775808 + n)
  putStrLn ("Int add: " ++ show [hiI + 1, hiI + hiI, loI + loI, loI + (-1)])
  putStrLn ("Int sub: " ++ show [loI - 1, loI - hiI, hiI - loI, 0 - loI])
  putStrLn ("Int mul: " ++ show [hiI * 2, hiI * hiI, loI * loI, loI * (-1), loI * 2, hiI * loI])
  putStrLn ("Int neg: " ++ show [negate loI, negate hiI, negate (loI + 1)])
  let hi64 : Int64 = fromInteger (9223372036854775807 + n)
  let lo64 : Int64 = fromInteger (-9223372036854775808 + n)
  putStrLn ("Int64 add: " ++ show [hi64 + 1, hi64 + hi64, lo64 + lo64, lo64 + (-1)])
  putStrLn ("Int64 sub: " ++ show [lo64 - 1, lo64 - hi64, hi64 - lo64, 0 - lo64])
  putStrLn ("Int64 mul: " ++ show [hi64 * 2, hi64 * hi64, lo64 * lo64, lo64 * (-1), lo64 * 2, hi64 * lo64])
  putStrLn ("Int64 neg: " ++ show [negate lo64, negate hi64, negate (lo64 + 1)])
  let hi32 : Int32 = fromInteger (2147483647 + n)
  let lo32 : Int32 = fromInteger (-2147483648 + n)
  putStrLn ("Int32 add: " ++ show [hi32 + 1, hi32 + hi32, lo32 + lo32, lo32 + (-1)])
  putStrLn ("Int32 sub: " ++ show [lo32 - 1, lo32 - hi32, hi32 - lo32, 0 - lo32])
  putStrLn ("Int32 mul: " ++ show [hi32 * 2, hi32 * hi32, lo32 * lo32, lo32 * (-1), lo32 * 2, hi32 * lo32])
  putStrLn ("Int32 neg: " ++ show [negate lo32, negate hi32, negate (lo32 + 1)])
  boxed "Int" (fromInteger {ty = Int} (-9223372036854775808)) (fromInteger {ty = Int} 9223372036854775807)
  boxed "Int64" (fromInteger {ty = Int64} (-9223372036854775808)) (fromInteger {ty = Int64} 9223372036854775807)
  boxed "Int32" (fromInteger {ty = Int32} (-2147483648)) (fromInteger {ty = Int32} 2147483647)
  boxed "Int16" (fromInteger {ty = Int16} (-32768)) (fromInteger {ty = Int16} 32767)
  boxed "Int8" (fromInteger {ty = Int8} (-128)) (fromInteger {ty = Int8} 127)
