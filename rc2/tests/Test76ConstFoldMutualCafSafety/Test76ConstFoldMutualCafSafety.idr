module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Safety-net regression for Compiler.RC2.RC2's `foldConstProgram`
-- whole-program fixpoint loop: `a`/`b` are two CAFs that reference
-- EACH OTHER (`a` builds `More 1 b`, `b` builds `More 2 a`), so neither
-- one's `cafValueOf` ever stabilizes to a single constant no matter how
-- many rounds `foldConstProgram` runs -- there is no correct fold here,
-- only a non-terminating one if the loop had no fixed iteration cap.
-- The one thing this test actually checks is that
-- `maxConstFoldIterations` bounds the loop and the program still
-- compiles and runs normally (un-folded `a`/`b`, ordinary `RAppName`
-- calls) rather than hanging the compiler or crashing at runtime.
--
-- `sumFirst 3 a` is never actually evaluated (`length args > 100` is
-- always false with no CLI arguments) -- it exists only to give the
-- compiler a live, statically-reachable use of the mutually-recursive
-- `a`/`b` pair, so `Compiler.RC2.DeadCode` can't just prune them away
-- before `ConstFold` even has anything to loop on.

import System

data Chain : Type where
  End : Chain
  More : Int -> Chain -> Chain

a : Chain
b : Chain

a = More 1 b
b = More 2 a

sumFirst : Nat -> Chain -> Int
sumFirst Z _ = 0
sumFirst (S k) End = 0
sumFirst (S k) (More x rest) = x + sumFirst k rest

main : IO ()
main = do
  args <- getArgs
  if length args > 100
     then printLn (sumFirst 3 a)
     else putStrLn "ok"
