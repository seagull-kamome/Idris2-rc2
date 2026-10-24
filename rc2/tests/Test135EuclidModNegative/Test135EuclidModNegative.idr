module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- `mod` and `div` of the signed integers are Euclidean: the remainder is never
-- negative, so a negative dividend that is a multiple of the divisor has
-- remainder 0 (not the divisor). Checked on the boxed path (operands taken
-- from a list, through the `Integral` dictionary) for every signed type, and on
-- the native path (operands computed at run time, so that they are not
-- constants) for `Int` and `Int8`.

import Data.List

-- (dividend, divisor)
pairs : List (Integer, Integer)
pairs = [(-6, 3), (-4, 2), (-7, 3), (7, 3), (7, -3), (-7, -3), (-6, -3), (0, 5), (-5, 5), (-1, 1)]

boxed : (Integral a, Neg a, Show a) => String -> (Integer -> a) -> IO ()
boxed name from = do
  let xs = map (\(n, d) => (from n, from d)) pairs
  putStrLn (name ++ " mod: " ++ show (map (\(a, b) => a `mod` b) xs))
  putStrLn (name ++ " div: " ++ show (map (\(a, b) => a `div` b) xs))

-- A number the compiler cannot see: how many elements a list has.
unseen : Nat -> Nat
unseen n = length (replicate n ())

nativeInt : IO ()
nativeInt = do
  let six = the Int (cast (unseen 6))
      three = the Int (cast (unseen 3))
      four = the Int (cast (unseen 4))
      two = the Int (cast (unseen 2))
  putStrLn ("Int native: " ++ show [ negate six `mod` three, negate four `mod` two
                                     , negate six `mod` negate three, negate (six + 1) `mod` three
                                     , negate six `div` three, negate (six + 1) `div` three ])

nativeInt8 : IO ()
nativeInt8 = do
  let six = the Int8 (cast (unseen 6))
      three = the Int8 (cast (unseen 3))
      four = the Int8 (cast (unseen 4))
      two = the Int8 (cast (unseen 2))
  putStrLn ("Int8 native: " ++ show [ negate six `mod` three, negate four `mod` two
                                      , negate six `mod` negate three, negate (six + 1) `mod` three
                                      , negate six `div` three, negate (six + 1) `div` three ])

main : IO ()
main = do
  boxed "Int" (fromInteger {ty = Int})
  boxed "Int8" (fromInteger {ty = Int8})
  boxed "Int16" (fromInteger {ty = Int16})
  boxed "Int32" (fromInteger {ty = Int32})
  boxed "Int64" (fromInteger {ty = Int64})
  nativeInt
  nativeInt8
