module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import System.Concurrency
import System.Concurrency.RC2
import Data.IORef
import System.Clock
import Data.List

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

nap : Int -> IO ()
nap ms = do
  mtx <- makeMutex
  cv <- makeCondition
  mutexAcquire mtx
  conditionWaitTimeout cv mtx (ms * 1000)
  mutexRelease mtx

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

  -- The whole time is waited for (not cut short by a wake-up), on the
  -- monotonic clock.
  t0 <- clockTime Monotonic
  _ <- channelGetWithTimeout empty 60
  t1 <- clockTime Monotonic
  putStrLn $ "a timed get waits out its time: " ++ show (toNano (timeDifference t1 t0) >= 55000000)

  -- A value that arrives while it waits is returned.
  chan2 <- makeChannel {a = Int}
  putter <- forkJoin {a = ()} $ nap 30 *> channelPut chan2 7
  got <- channelGetWithTimeout chan2 5000
  join putter
  putStrLn $ "channelGetWithTimeout gets a value that arrives while it waits: " ++ show got

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
  -- A heap value: the slot must hold its own reference, as the FFI wrapper
  -- drops the caller's right after the call. Churn the allocator so a freed
  -- cell would be reused, then replace the value (the old one is dropped).
  n <- pure (the Int 12345)
  setThreadData {a = String} ("hello" ++ show n ++ pack (replicate 40 'x'))
  let junk = map (\i => show i ++ "-" ++ show (i * 7)) (the (List Int) [1 .. 2000])
  putStrLn $ "junk: " ++ show (length junk)
  s1 <- getThreadData String
  putStrLn $ "setThreadData String round-trip: " ++ s1
  setThreadData {a = List Int} [1, 2, 3]
  xs <- getThreadData (List Int)
  putStrLn $ "setThreadData List round-trip: " ++ show xs

-- Threads that exit with a value in their slot: the slot's destructor drops it
-- (under the address sanitizer, a leak or a double drop shows up here).
testThreadDataAtExit : IO ()
testThreadDataAtExit = do
  handles <- for (the (List Int) [1 .. 8]) $ \i => forkJoin {a = String} $ do
    setThreadData {a = String} ("thread" ++ show i ++ pack (replicate 40 'y'))
    setThreadData {a = String} ("again" ++ show i ++ pack (replicate 40 'z'))
    getThreadData String
  rs <- for handles join
  putStrLn $ "thread data survives until exit: " ++ show (map (length . unpack) rs)

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
  testThreadDataAtExit

  putStrLn "--- Tests finished ---"
