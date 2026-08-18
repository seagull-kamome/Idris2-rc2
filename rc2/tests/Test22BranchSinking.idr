module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Exercises Compiler.RC2.Sink's branch-local sinking as a general,
-- loop-independent pass (unlike Test21BoxedInvariantNotHoisted.idr,
-- which exercises the same pass but specifically inside a self-tail
-- loop): `sinkable`'s `ctx` is only ever read on the `True` arm, so
-- its own construction should move into that arm entirely, leaving
-- the `False` arm untouched; `notSinkable`'s `ctx` is read on *both*
-- arms, so it must stay exactly where it is -- sinking it into either
-- one would leave the other with no value to read at all.
data Pair2 = MkPair2 Int Int

sinkable : Bool -> Int -> Int -> Int
sinkable flag a b =
  let ctx = MkPair2 a b
  in if flag
        then case ctx of MkPair2 x y => x + y
        else 0

notSinkable : Bool -> Int -> Int -> Int
notSinkable flag a b =
  let ctx = MkPair2 a b
  in if flag
        then case ctx of MkPair2 x y => x + y
        else case ctx of MkPair2 x y => x - y

main : IO ()
main = do
  printLn (sinkable True 3 4)
  printLn (sinkable False 3 4)
  printLn (notSinkable True 10 3)
  printLn (notSinkable False 10 3)
