module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- `when c act`, `unless c act` and `if c then act1 else act2` over IO actions
-- leave `case c of ... -> <closure>` applied to the world once `when` is spliced.
-- Pushing the apply into the branches turns each closure into a direct call
-- (rc2/doc/inlining.md, "Pushing an apply into the tails"). check.sh compares the
-- number of partial applications with `--directive nopushapply`; the output
-- must be the same, and valgrind (LEAK_SENSITIVE_TESTS) sees no leak.

import Data.IORef
import System

step : IORef Int -> IORef Int -> Int -> IO ()
step r s n = do
  when (n `mod` 3 == 0) (modifyIORef r (+ n))
  unless (n `mod` 2 == 0) (modifyIORef s (+ 1))
  if n `mod` 5 == 0 then modifyIORef r (subtract 1) else modifyIORef s (* 1)

-- Other shapes of the branching value: a tail that is a local action, a tail
-- that is a call returning an action, nine alternatives (over the limit of
-- eight tails), a case on a constant, and a `when` inside a `when`.
bump : IORef Int -> Int -> IO ()
bump r d = modifyIORef r (+ d)

shapes : IORef Int -> Int -> IO ()
shapes r n = do
  let local = bump r 1
  (if n `mod` 2 == 0 then local else pure ())
  (if n `mod` 3 == 0 then bump r 2 else local)
  (case n `mod` 9 of
     0 => bump r 10
     1 => bump r 11
     2 => bump r 12
     3 => bump r 13
     4 => bump r 14
     5 => bump r 15
     6 => bump r 16
     7 => bump r 17
     _ => pure ())
  (case n `mod` 4 of
     0 => local
     1 => bump r 100
     _ => pure ())
  when (n `mod` 2 == 0) (when (n `mod` 3 == 0) (bump r 1000))

loop : IORef Int -> IORef Int -> Int -> IO ()
loop r s 0 = pure ()
loop r s n = step r s n >> shapes r n >> loop r s (n - 1)

main : IO ()
main = do
  args <- getArgs
  let k : Int = case args of { (_ :: a :: _) => cast a; _ => 100 }
  r <- newIORef 0
  s <- newIORef 0
  loop r s k
  readIORef r >>= printLn
  readIORef s >>= printLn
  when (k > 50) (putStrLn "large")
  when (k > 5000) (putStrLn "huge")
  unless (k > 5000) (putStrLn "not huge")
