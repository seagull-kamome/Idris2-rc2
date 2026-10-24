module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Branch sinking (rc2/doc/branch-sinking.md) moves a value that only one arm uses
-- into that arm. When the value reads one local twice (`x * x`, `(x, x)`) and the
-- local was `dup`'d first, the arm that does not get the value owes nothing for
-- those references; but the reference the local arrived with is still owed a drop
-- in every other arm (the local is dead after the branch, so nothing else drops
-- it). The Integers are beyond the immediate range (62 bits), so
-- they are real heap cells; valgrind (this test is in LEAK_SENSITIVE_TESTS) must
-- see neither a double free nor a leak.

import System

%default total

-- keep each helper a function of its own: the sunk value is in its body
%cg rc2 noinline

-- an operator reading the same operand twice, sunk into one arm
mulTwiceH : Int -> Integer -> Integer
mulTwiceH k x =
  let r = x * x
  in case k of
          0 => 0
          _ => r + 1

mulTwiceF : Int -> Integer -> Integer
mulTwiceF k x = mulTwiceH k x

-- a constructor with the same field twice, sunk into one arm
pairTwiceH : Int -> Integer -> (Integer, Integer)
pairTwiceH k x =
  let p = (x, x)
  in case k of
          0 => (0, 0)
          _ => p

pairTwiceF : Int -> Integer -> Integer
pairTwiceF k x = let (a, b) = pairTwiceH k x in a + b

-- the same local three times
tripleTwiceH : Int -> Integer -> (Integer, Integer, Integer)
tripleTwiceH k x =
  let p = (x, x, x)
  in case k of
          0 => (0, 0, 0)
          _ => p

tripleTwiceF : Int -> Integer -> Integer
tripleTwiceF k x = let (a, b, c) = tripleTwiceH k x in a + b + c

main : IO ()
main = do
  -- nothing the compiler can see: the number of command line arguments
  -- (the program name counts, so `n` is 1 and `n - 1` is 0)
  args <- getArgs
  let n : Int = cast (length args)
      big : Integer = 4611686018427387904 + cast n
  printLn (mulTwiceF (n - 1) big)
  printLn (mulTwiceF n big)
  printLn (pairTwiceF (n - 1) big)
  printLn (pairTwiceF n big)
  printLn (tripleTwiceF (n - 1) big)
  printLn (tripleTwiceF n big)
