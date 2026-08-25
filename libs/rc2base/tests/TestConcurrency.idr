module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import System.Concurrency
import System.Concurrency.RC2
import Data.IORef
import Data.List

-- Both System.Concurrency and System.Concurrency.RC2 export a Channel
-- API; this test exercises RC2's (see RC2.idr's own module-level %hide
-- for why upstream's own Channel/channel* can't be used from a C backend).
%hide System.Concurrency.Channel
%hide System.Concurrency.makeChannel
%hide System.Concurrency.channelPut
%hide System.Concurrency.channelGet
%hide System.Concurrency.channelGetNonBlocking
%hide System.Concurrency.channelGetWithTimeout

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

testSemaphore : IO ()
testSemaphore = do
  sema <- makeSemaphore 0
  handle <- forkJoin {a = Int} $ do
    semaphoreWait sema
    pure 42
  semaphorePost sema
  -- join (not a fixed sleep) is what actually establishes a
  -- happens-before edge with the waiter thread's result.
  r <- join handle
  putStrLn $ "Semaphore post/wait ran: " ++ show (r == 42)

testBarrier : IO ()
testBarrier = do
  barrier <- makeBarrier (cast barrierParties)
  mtx <- makeMutex -- shared across all parties; a per-thread mutex would give no exclusion at all
  doneRef <- newIORef 0
  handles <- for [1 .. barrierParties] $ \_ =>
    forkJoin {a = ()} $ do
      barrierWait barrier
      mutexAcquire mtx
      n <- readIORef doneRef
      writeIORef doneRef (n + 1)
      mutexRelease mtx
  for_ handles join
  n <- readIORef doneRef
  putStrLn $ "Barrier released all " ++ show barrierParties ++ " parties: " ++ show (n == barrierParties)
  where
    barrierParties : Int
    barrierParties = 4

testChannel : IO ()
testChannel = do
  chan <- makeChannel
  handles <- for [1 .. 3] $ \i => forkJoin {a = ()} $ channelPut chan (i * 10)
  for_ handles join
  vals <- for [1, 2, 3] $ \_ => channelGet chan
  putStrLn $ "Channel got 3 values summing to 60: " ++ show (sum vals == 60)

  empty <- makeChannel {a = Int}
  none <- channelGetNonBlocking empty
  putStrLn $ "channelGetNonBlocking on empty channel: " ++ show none

  timedOut <- channelGetWithTimeout empty 20
  putStrLn $ "channelGetWithTimeout on empty channel: " ++ show timedOut

testJoinableFork : IO ()
testJoinableFork = do
  handle <- forkJoin (pure (2 + 2))
  result <- join handle
  putStrLn $ "forkJoin/join result (expected 4): " ++ show result

testConditionWaitTimeout : IO ()
testConditionWaitTimeout = do
  mtx <- makeMutex
  cv <- makeCondition
  mutexAcquire mtx
  -- Nobody ever signals cv, so this should simply time out and return.
  conditionWaitTimeout cv mtx 20000
  mutexRelease mtx
  putStrLn "conditionWaitTimeout returned without deadlocking"

testThreadIdAndData : IO ()
testThreadIdAndData = do
  tid <- getThreadId
  putStrLn $ "getThreadId returned: " ++ show (tid >= 0)
  setThreadData {a = Int} 99
  back <- getThreadData Int
  putStrLn $ "setThreadData/getThreadData round-trip: " ++ show (back == 99)

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

  testJoinableFork
  testSemaphore
  testBarrier
  testChannel
  testConditionWaitTimeout
  testThreadIdAndData

  putStrLn "--- Tests finished ---"
