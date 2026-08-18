module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Exercises Compiler.RC2.Loop's loop-invariant EXPRESSION hoisting
-- (ROp/RCon in the loop body's own unconditional prefix, depending
-- only on non-loop-carried ids): `bound` is recomputed from `limit`
-- (itself a loop-invariant native shadow hoisted by the parameter-
-- elision pass) on every iteration but never actually changes, so it
-- should get hoisted to a one-time computation ahead of the loop too.
sumBounded : Int -> Int -> Int -> Int
sumBounded limit acc n =
  let bound = limit * 2
  in if n >= bound
        then acc
        else sumBounded limit (acc + n) (n + 1)

main : IO ()
main = printLn (sumBounded 500 0 0)
