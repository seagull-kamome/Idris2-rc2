module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- `compare` on `Integer` (what every `Nat` comparison is built on) is small
-- once the case on a literal is reduced (rc2/doc/inlining.md, "Case of a
-- literal"), so it is spliced into each of its callers instead of being
-- called. With more than one caller `LateInline` cannot do it, hence the
-- several functions below. check.sh looks at the IR; the output must be right
-- either way.

import Data.List

lt : Nat -> Nat -> Bool
lt x y = x < y

ge : Nat -> Nat -> Bool
ge x y = x >= y

gt : Nat -> Nat -> Bool
gt x y = x > y

le : Nat -> Nat -> Bool
le x y = x <= y

ord : Integer -> Integer -> Ordering
ord x y = compare x y

main : IO ()
main = do
  n <- pure (length (the (List Nat) [1, 2, 3]))
  putStrLn (show [lt n 2, lt n 3, lt n 4, ge n 2, ge n 3, ge n 4])
  putStrLn (show [gt n 2, gt n 3, gt n 4, le n 2, le n 3, le n 4])
  putStrLn (show [ord 1 2, ord 2 2, ord 3 2])
  putStrLn (show (sort [n, 2, 1, 5, 4]))
