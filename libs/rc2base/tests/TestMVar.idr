module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Control.Concurrent.MVar
import Data.IORef
import Data.List
import System.Concurrency.RC2

testBasic : IO ()
testBasic = do
  mv <- newMVar 10
  x <- takeMVar mv
  putMVar mv 20
  y <- readMVar mv
  z <- readMVar mv
  putStrLn $ "newMVar/takeMVar/putMVar/readMVar: " ++
    show (x == 10 && y == 20 && z == 20)

testTryAndEmpty : IO ()
testTryAndEmpty = do
  mv <- newEmptyMVar {a = Int}
  e1 <- isEmptyMVar mv
  none <- tryTakeMVar mv
  ok1 <- tryPutMVar mv 5
  e2 <- isEmptyMVar mv
  ok2 <- tryPutMVar mv 6
  Just v <- tryTakeMVar mv
    | Nothing => putStrLn "FAIL: tryTakeMVar returned Nothing unexpectedly"
  putStrLn $ "isEmptyMVar/tryTakeMVar/tryPutMVar: " ++
    show (e1 && none == Nothing && ok1 && not e2 && not ok2 && v == 5)

testSwap : IO ()
testSwap = do
  mv <- newMVar "a"
  old <- swapMVar mv "b"
  new <- readMVar mv
  putStrLn $ "swapMVar: " ++ show (old == "a" && new == "b")

testModify : IO ()
testModify = do
  mv <- newMVar 1
  modifyMVar_ mv (\n => pure (n + 1))
  r <- modifyMVar mv (\n => pure (n * 2, n))
  final <- readMVar mv
  withResult <- withMVar mv (\n => pure (n + 100))
  stillThere <- readMVar mv
  putStrLn $ "modifyMVar_/modifyMVar/withMVar: " ++
    show (r == 2 && final == 4 && withResult == 104 && stillThere == 4)

-- Proves mutual exclusion actually holds: `workerCount` threads each
-- increment the shared counter `iterCount` times via `modifyMVar_`, no
-- lock of their own -- any interleaving that loses an update would
-- show up directly as a final count short of workerCount * iterCount.
workerCount : Int
workerCount = 8

iterCount : Int
iterCount = 500

testConcurrentModify : IO ()
testConcurrentModify = do
  mv <- newMVar 0
  handles <- for [1 .. workerCount] $ \_ =>
    forkJoin {a = ()} $
      for_ [1 .. iterCount] $ \_ =>
        modifyMVar_ mv (\n => pure (n + 1))
  for_ handles join
  final <- readMVar mv
  putStrLn $ "concurrent modifyMVar_ (expected " ++ show (workerCount * iterCount) ++
    "): " ++ show (final == workerCount * iterCount)

-- Proves takeMVar/putMVar genuinely block rather than erroring or
-- returning early: a forked reader blocks on `takeMVar` against an
-- initially-empty MVar until the main thread explicitly `putMVar`s --
-- `join` only returns once that actually happened, establishing a
-- real happens-before edge rather than relying on a fixed sleep.
testBlockingHandoff : IO ()
testBlockingHandoff = do
  mv <- newEmptyMVar {a = Int}
  handle <- forkJoin {a = Int} (takeMVar mv)
  putMVar mv 77
  r <- join handle
  putStrLn $ "blocking takeMVar/putMVar handoff: " ++ show (r == 77)

main : IO ()
main = do
  putStrLn "--- Testing Control.Concurrent.MVar ---"
  testBasic
  testTryAndEmpty
  testSwap
  testModify
  testConcurrentModify
  testBlockingHandoff
  putStrLn "--- Tests finished ---"
