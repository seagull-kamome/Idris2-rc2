||| A pool of worker threads for `Control.Task.blocking`: the scheduler hands an
||| action to a worker and goes on. The workers are started lazily, when a job
||| comes and none is idle, up to a limit; the first thread of a program turns
||| rc2's reference counts atomic (`rc2/doc/hybrid-refcount.md`), so a program
||| that never offloads must not pay for it. With a limit of 0 the action runs at
||| once on the calling thread. Design: libs/rc2base/doc/task.md ("N:M").
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Control.Task.Pool

import Control.Task
import Data.IORef
import Data.List
import Data.Queue
import System.Concurrency
import System.Concurrency.RC2

%default covering

record Job where
  constructor MkJob
  cancelled : IORef Bool
  act : IO ()

export
record Pool where
  constructor MkPool
  limit : Nat
  lock : Mutex
  cond : Condition
  queue : IORef (Queue Job)
  started : IORef Nat
  idle : IORef Nat
  stopping : IORef Bool
  handles : IORef (List (JoinHandle ()))

||| A pool that will start at most `limit` workers.
export
newPool : (limit : Nat) -> IO Pool
newPool limit = do
  lock <- makeMutex
  cond <- makeCondition
  [| MkPool (pure limit) (pure lock) (pure cond) (newIORef Queue.empty) (newIORef 0) (newIORef 0)
            (newIORef False) (newIORef []) |]

-- The next job, waiting for one; `Nothing` when the pool is stopping. Called
-- with the lock held.
takeJob : Pool -> IO (Maybe Job)
takeJob p = do
  stop <- readIORef p.stopping
  if stop then pure Nothing else do
    q <- readIORef p.queue
    case dequeue q of
      Just (j, rest) => writeIORef p.queue rest *> pure (Just j)
      Nothing => do
        modifyIORef p.idle S
        conditionWait p.cond p.lock
        modifyIORef p.idle (`minus` 1)
        takeJob p

worker : Pool -> IO ()
worker p = do
  mutexAcquire p.lock
  job <- takeJob p
  mutexRelease p.lock
  case job of
    Nothing => pure ()
    Just j => do
      skip <- readIORef j.cancelled
      unless skip j.act
      worker p

||| Run the action on a worker thread. The result takes the job back if it has
||| not started (one that has started runs to its end). With a limit of 0 the
||| action runs now, on this thread, and there is nothing to take back.
export
offload : Pool -> IO () -> IO Cancel
offload p act =
  if p.limit == 0 then act *> pure noCancel else do
    cancelled <- newIORef False
    mutexAcquire p.lock
    modifyIORef p.queue (enqueue (MkJob cancelled act))
    q <- readIORef p.queue
    n <- readIORef p.started
    idle <- readIORef p.idle
    let wanted = n < p.limit && Queue.length q > idle
    when wanted $ writeIORef p.started (S n)
    conditionSignal p.cond
    mutexRelease p.lock
    when wanted $ do
      h <- forkJoin (worker p)
      modifyIORef p.handles (h ::)
    pure (MkCancel (writeIORef cancelled True))

||| Stop the workers (jobs still queued are forgotten) and wait for them.
export
closePool : Pool -> IO ()
closePool p = do
  mutexAcquire p.lock
  writeIORef p.stopping True
  conditionBroadcast p.cond
  mutexRelease p.lock
  hs <- readIORef p.handles
  writeIORef p.handles []
  traverse_ join hs
