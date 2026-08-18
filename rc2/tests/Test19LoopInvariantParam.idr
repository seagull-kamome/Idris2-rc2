module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Exercises Compiler.RC2.Loop's invariant-loop-param elision: `tag`
-- (Boxed) and `limit` (native-shadow-eligible) are both threaded
-- through every continue completely unchanged -- both should disappear
-- from the loop's own loopParams/initial/continue-args, with `limit`
-- additionally getting hoisted into a one-time RLet+RDrop native read
-- ahead of the loop (mirroring Compiler.RC2.ConAltNative's own field
-- caching).
sumWithTag : String -> Int -> Int -> Int -> Int
sumWithTag tag limit acc n =
  if n >= limit
     then acc + cast (length tag)
     else sumWithTag tag limit (acc + n) (n + 1)

main : IO ()
main = printLn (sumWithTag "ctx" 1000 0 0)
