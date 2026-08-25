module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import System.Concurrency
import System.Concurrency.RC2
import Data.IORef

workerCount : Int
workerCount = 5

worker : Mutex -> Condition -> IORef Int -> IORef Int -> IO ()
worker mtx cv counterRef doneRef = do
  mutexAcquire mtx
  n <- readIORef counterRef
  writeIORef counterRef (n + 1)
  mutexRelease mtx

  mutexAcquire mtx
  d <- readIORef doneRef
  writeIORef doneRef (d + 1)
  when (d + 1 == workerCount) $ conditionSignal cv
  mutexRelease mtx

waitForAll : Mutex -> Condition -> IORef Int -> IO ()
waitForAll mtx cv doneRef = do
  mutexAcquire mtx
  loop
  mutexRelease mtx
  where
    loop : IO ()
    loop = do
      d <- readIORef doneRef
      if d >= workerCount
        then pure ()
        else do
          conditionWait cv mtx
          loop

main : IO ()
main = do
  putStrLn "--- Testing System.Concurrency.RC2 ---"

  mtx <- makeMutex
  cv <- makeCondition
  counterRef <- newIORef 0
  doneRef <- newIORef 0

  for_ [1 .. workerCount] $ \_ =>
    ignore $ fork (worker mtx cv counterRef doneRef)

  waitForAll mtx cv doneRef

  final <- readIORef counterRef
  putStrLn $ "Final counter (expected " ++ show workerCount ++ "): " ++ show final

  putStrLn "--- Tests finished ---"
