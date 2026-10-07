module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Sink moves `let r = g xs ys` (lowered to `dup xs; dup ys; call g
-- [xs, ys]`) into the one arm that reads `r`. The call's operands were
-- dup'd first, so the call spends only the dups: the other arm must
-- not get a compensating `drop [xs, ys]` (rc2/doc/branch-sinking.md,
-- "Sinking a call whose operands were dup'd first"). Both lists are
-- read again after the branch, so the spurious drop is a double drop.

g : List Int -> List Int -> Int
g [] ys = cast (length ys)
g (_ :: t) ys = 1 + g t ys

h : Int -> List Int -> List Int -> Int
h k xs ys =
  let r = g xs ys
  in case k of
          0 => 0
          _ => r + 1

f : Int -> List Int -> List Int -> Int
f k xs ys = h k xs ys + cast (length xs) + cast (length ys)

main : IO ()
main = do
  let xs = [10000000000000000000, 2, 3]
      ys = [4000000000000000000, 5]
  printLn (f 0 xs ys)
  printLn (f 1 xs ys)
  printLn (f 0 (map (+ 1) xs) (map (+ 1) ys))
  printLn (f 1 (map (+ 1) xs) (map (+ 1) ys))
