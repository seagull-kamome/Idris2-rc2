module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for a real double-free found while implementing
-- Compiler.RC2.Loop's loop-invariant expression hoisting: a Boxed
-- (never native-shadowed) constructor built from invariant fields,
-- used only on the loop's own exit arm and never on the continuing
-- arm, must NOT be hoisted out of the loop -- the continuing arm's own
-- ownership bookkeeping still contains a per-iteration `drop` for it
-- (it's dead/unused on that arm in the *original*, per-iteration
-- construction), which would double-free the one, shared, hoisted
-- value on every iteration that takes it if hoisting fired here.
-- Confirmed via valgrind before this test existed: `malloc(): unaligned
-- tcache chunk detected` without the `isNativeRep` guard in
-- `hoistInvariantPrefix`.
data Ctx = MkCtx String Int

sumOrCtx : String -> Int -> Int -> Int -> Int -> Ctx
sumOrCtx tag extra acc n limit =
  let ctx = MkCtx tag extra
  in if n >= limit
        then ctx
        else sumOrCtx tag extra (acc + n) (n + 1) limit

main : IO ()
main = case sumOrCtx "hello" 42 0 0 3 of
            MkCtx s e => putStrLn (s ++ show e)
