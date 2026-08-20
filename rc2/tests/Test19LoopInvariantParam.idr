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

data Box = MkBox Int Int

showBox : Box -> Int
showBox (MkBox l a) = l + a

-- `limit` (native-shadow-eligible, invariant) is also read in a Boxed
-- context (`MkBox limit acc`) on the loop's own *continue* path --
-- exercises `dupInvariantBoxed`'s own unconditional-dup rule: every
-- iteration that actually reaches this arm re-`dup`s `limit`'s own
-- original Boxed identity rather than moving it (a move here would be
-- a use-after-free on the *next* iteration's own read).
sumWithBoxedContinuePath : Int -> Int -> Int -> Int
sumWithBoxedContinuePath limit acc n =
  if n >= limit
     then acc
     else sumWithBoxedContinuePath limit (showBox (MkBox limit acc)) (n + 1)

-- `limit` is read in a Boxed context only once, on the loop's own
-- *exit* arm -- the shape where `dupInvariantBoxed`'s own
-- unconditional dup costs one extra (but still correct) reference
-- versus a hypothetical move-on-last-use optimisation this pass
-- deliberately doesn't attempt (see this module's own header note on
-- why).
sumWithBoxedExitOnly : Int -> Int -> Int -> Int
sumWithBoxedExitOnly limit acc n =
  if n >= limit
     then acc + showBox (MkBox limit acc)
     else sumWithBoxedExitOnly limit (acc + n) (n + 1)

main : IO ()
main = do
  printLn (sumWithTag "ctx" 1000 0 0)
  printLn (sumWithBoxedContinuePath 1000 0 0)
  printLn (sumWithBoxedExitOnly 1000 0 0)
