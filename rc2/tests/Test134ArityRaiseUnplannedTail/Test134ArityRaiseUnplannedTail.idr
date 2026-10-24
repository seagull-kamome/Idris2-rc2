module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- World arity raising (rc2/doc/world-arity-raising.md) must call the raised
-- version of a tail callee only when the callee is raised itself.
--
-- `pingC` and `pongC` only call each other: every tail is a call to a
-- function of the set, so they pass the greatest fixpoint, but neither has a
-- lambda tail and so neither is raised. `sumPos` is raised (it has lambda tails)
-- and tail calls `pingC`; that call has to stay as it is. The program
-- is never run through `pingC`: it must only link.

%default covering

record Core t where
  constructor MkCore
  runCore : IO (Either String t)

pure' : a -> Core a
pure' x = MkCore (pure (Right x))

bind : Core a -> (a -> Core b) -> Core b
bind (MkCore act) k = MkCore $ do
  r <- act
  case r of
    Left e => pure (Left e)
    Right x => runCore (k x)

mutual
  pingC : Nat -> Core Int
  pingC n = pongC (S n)

  pongC : Nat -> Core Int
  pongC n = pingC (S n)

sumPos : List Int -> Core Int
sumPos [] = pure' 0
sumPos (x :: xs) =
  if x < 0 then pingC 0
  else sumPos xs `bind` \s => pure' (s + x)

main : IO ()
main = do
  r <- runCore (sumPos [1, 2, 3])
  printLn r
