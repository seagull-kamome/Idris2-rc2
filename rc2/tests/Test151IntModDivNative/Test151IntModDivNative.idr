module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- `mod`/`div` on a fixed-width integer by a constant: `Prelude.Num.mod` is a
-- `case y == 0 of ...` until inlining and ConstFold leave the bare op, which
-- gets a native rep again (rc2/doc/native-type-inference.md, "Refreshing a rep
-- after folding"). check.sh looks at the IR; the values must be right either
-- way, negative operands included (Euclidean).

import System

modInt : Int -> Int
modInt n = n `mod` 7

divInt : Int -> Int
divInt n = n `div` 7

modI32 : Int32 -> Int32
modI32 n = n `mod` 5

divB8 : Bits8 -> Bits8
divB8 n = n `div` 4

sumMods : Int -> Int -> Int
sumMods 0 acc = acc
sumMods n acc = sumMods (n - 1) (acc + n `mod` 3 + n `div` 5)

row : Int -> String
row n = show (modInt n, divInt n, modInt (negate n), divInt (negate n))

main : IO ()
main = do
  args <- getArgs
  let k : Int = case args of { (_ :: a :: _) => cast a; _ => 10 }
  putStrLn (row k)
  putStrLn (row (k * 1000003))
  putStrLn (show (modI32 (cast k), modI32 (negate (cast k)), divB8 (cast k)))
  putStrLn (show (sumMods 1000 0))
  putStrLn (show (sumMods (k * 100) 0))
