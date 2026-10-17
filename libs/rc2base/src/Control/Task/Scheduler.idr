||| The scheduler of `Control.Task`: runs the tasks of one thread, waits for
||| the sources (the readiness of descriptors and any other the program
||| adds) and the timers. Design: libs/rc2base/doc/task.md.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Control.Task.Scheduler

import Control.Task
import Control.Task.Epoll
import Control.Task.Source
import Data.Bits
import Data.IORef
import Data.List
import Data.Maybe
import Data.Queue
import Data.SortedMap
import System.Concurrency
import System.Linux.Epoll
import System.Linux.Eventfd
import System.Posix.Errno
import System.Posix.FileDesc
import System.Posix.Time

%default covering

-------------------------------------------------------------------------------
-- Scopes

-- The tasks of a `race` run in a scope of their own; cancelling it gives up
-- their operations, drops their ready steps and cancels the scopes below.
record Scope where
  constructor MkScope
  cancelled : IORef Bool
  cleanups : IORef (SortedMap Nat (IO ()))
  children : IORef (SortedMap Nat Scope)

newRootScope : IO Scope
newRootScope = [| MkScope (newIORef False) (newIORef empty) (newIORef empty) |]

cancelScope : Scope -> IO ()
cancelScope sc = do
  done <- readIORef sc.cancelled
  unless done $ do
    writeIORef sc.cancelled True
    cs <- readIORef sc.cleanups
    writeIORef sc.cleanups empty
    kids <- readIORef sc.children
    writeIORef sc.children empty
    traverse_ id (values cs)
    traverse_ cancelScope (values kids)

-------------------------------------------------------------------------------
-- The scheduler

export
record Scheduler where
  constructor MkScheduler
  runQ : IORef (Queue (Scope, IO ()))
  pending : IORef Nat                          -- operations started and not over
  counter : IORef Nat
  timers : IORef (SortedMap (Time, Nat) (IO ()))
  master : EPoll
  sources : IORef (SortedMap Int32 Source)
  root : Scope
  watcher : FdWatcher
  lock : Mutex
  inbox : IORef (List (IO ()))
  inboxFd : FileDesc

fresh : Scheduler -> IO Nat
fresh s = do
  n <- readIORef s.counter
  writeIORef s.counter (S n)
  pure n

enqueue : Scheduler -> Scope -> IO () -> IO ()
enqueue s sc act = modifyIORef s.runQ (Queue.enqueue (sc, act))

||| The monotonic clock in milliseconds.
nowMs : IO Time
nowMs = do
  Right t <- clock_gettime CLOCK_MONOTONIC
    | Left _ => pure 0
  pure (cast (t.tvSec * 1000 + t.tvNsec `div` 1000000))

-- Run an action on the thread of the scheduler, from any thread.
postTo : Scheduler -> IO () -> IO ()
postTo s act = do
  mutexAcquire s.lock
  modifyIORef s.inbox (act ::)
  mutexRelease s.lock
  ignore (eventfdWrite s.inboxFd 1)

envOf : Scheduler -> Env
envOf s = MkEnv nowMs addTimer (\fd, ev, done => watch s.watcher fd ev done) (postTo s)
  where
    addTimer : Time -> IO () -> IO Cancel
    addTimer t act = do
      ident <- fresh s
      modifyIORef s.timers (insert (t, ident) act)
      pure (MkCancel (modifyIORef s.timers (delete (t, ident))))

-------------------------------------------------------------------------------
-- The interpreter

mutual
  run : Scheduler -> Scope -> Task a -> (a -> IO ()) -> IO ()
  run s sc (Point io) k = enqueue s sc (io >>= k)
  run s sc (Seq t f) k = run s sc t (\a => run s sc (f a) k)
  run s sc (Both l r) k = runBoth s sc l r k
  run s sc (Race Empty r) k = run s sc r k
  run s sc (Race l Empty) k = run s sc l k
  run s sc (Race l r) k = runRace s sc l r k
  run s sc (Spawn t) k = do
    enqueue s sc (run s sc t (\_ => pure ()))
    k ()
  run s sc (Async f) k = runAsync s sc f k
  run _ _ Empty _ = pure ()

  runBoth : Scheduler -> Scope -> Task a -> Task b -> ((a, b) -> IO ()) -> IO ()
  runBoth s sc l r k = do
    ra <- newIORef Nothing
    rb <- newIORef Nothing
    enqueue s sc $ run s sc l $ \a => do
      mb <- readIORef rb
      case mb of
        Just b => enqueue s sc (k (a, b))
        Nothing => writeIORef ra (Just a)
    enqueue s sc $ run s sc r $ \b => do
      ma <- readIORef ra
      case ma of
        Just a => enqueue s sc (k (a, b))
        Nothing => writeIORef rb (Just b)

  runRace : Scheduler -> Scope -> Task a -> Task a -> (a -> IO ()) -> IO ()
  runRace s sc l r k = do
    ident <- fresh s
    child <- newRootScope
    modifyIORef sc.children (insert ident child)
    won <- newIORef False
    let finish = \a => do
          already <- readIORef won
          unless already $ do
            writeIORef won True
            cancelScope child
            modifyIORef sc.children (delete ident)
            enqueue s sc (k a)
    enqueue s child (run s child l finish)
    enqueue s child (run s child r finish)

  runAsync : Scheduler -> Scope -> (Env -> Completion a -> IO Cancel) -> (a -> IO ()) -> IO ()
  runAsync s sc f k = do
    gone <- readIORef sc.cancelled
    unless gone $ do
      ident <- fresh s
      fired <- newIORef False
      modifyIORef s.pending S
      let complete = \x => do
            already <- readIORef fired
            unless already $ do
              writeIORef fired True
              modifyIORef s.pending (`minus` 1)
              modifyIORef sc.cleanups (delete ident)
              enqueue s sc (k x)
      giveUp <- f (envOf s) complete
      already <- readIORef fired
      unless already $
        modifyIORef sc.cleanups $ insert ident $ do
          over <- readIORef fired
          unless over $ do
            writeIORef fired True
            modifyIORef s.pending (`minus` 1)
            runCancel giveUp

-------------------------------------------------------------------------------
-- Turns

-- Run up to `n` of the ready steps.
runBatch : Scheduler -> Nat -> IO ()
runBatch _ Z = pure ()
runBatch s (S n) = do
  q <- readIORef s.runQ
  case dequeue q of
    Nothing => pure ()
    Just ((sc, act), rest) => do
      writeIORef s.runQ rest
      gone <- readIORef sc.cancelled
      unless gone act
      runBatch s n

-- Run the timers that are due.
fireTimers : Scheduler -> IO ()
fireTimers s = do
  now <- nowMs
  tm <- readIORef s.timers
  case leftMost tm of
    Just ((t, ident), act) =>
      if t <= now
         then do modifyIORef s.timers (delete (t, ident))
                 act
                 fireTimers s
         else pure ()
    Nothing => pure ()

-- How long the wait may last, in milliseconds; -1 for no limit.
waitTime : Scheduler -> IO Int32
waitTime s = do
  q <- readIORef s.runQ
  if Queue.length q > 0 then pure 0 else do
    tm <- readIORef s.timers
    case leftMost tm of
      Nothing => pure (-1)
      Just ((t, _), _) => do
        now <- nowMs
        pure (cast (t `minus` now))

addSourceRaw : Scheduler -> Source -> IO (Either Errno ())
addSourceRaw s src = do
  r <- epollAdd s.master src.pollFd EPOLLIN
  case r of
    Left e => pure (Left e)
    Right () => do
      modifyIORef s.sources (insert src.pollFd.rawfd src)
      pure (Right ())

-------------------------------------------------------------------------------
-- The public interface

||| A scheduler with the sources for descriptors and for other threads.
export
newScheduler : IO (Either Errno Scheduler)
newScheduler = do
  Right master <- epollCreate 16
    | Left e => pure (Left e)
  Right watcher <- newFdWatcher
    | Left e => ignore (epollClose master) *> pure (Left e)
  Right inboxFd <- eventfd 0 (EFD_NONBLOCK .|. EFD_CLOEXEC)
    | Left e => ignore (epollClose master) *> closeFdWatcher watcher *> pure (Left e)
  lock <- makeMutex
  root <- newRootScope
  s <- [| MkScheduler (newIORef Queue.empty) (newIORef 0) (newIORef 0) (newIORef empty) (pure master)
                      (newIORef empty) (pure root) (pure watcher) (pure lock) (newIORef []) (pure inboxFd) |]
  Right () <- addSourceRaw s (watcherSource watcher)
    | Left e => pure (Left e)
  Right () <- addSourceRaw s (MkSource inboxFd (drainInbox s))
    | Left e => pure (Left e)
  pure (Right s)
  where
    drainInbox : Scheduler -> IO ()
    drainInbox s = do
      _ <- eventfdRead s.inboxFd
      mutexAcquire s.lock
      acts <- readIORef s.inbox
      writeIORef s.inbox []
      mutexRelease s.lock
      traverse_ id (reverse acts)

||| Release the descriptors of the scheduler. Operations still pending are
||| forgotten.
export
closeScheduler : Scheduler -> IO ()
closeScheduler s = do
  ignore (epollClose s.master)
  closeFdWatcher s.watcher
  ignore (close s.inboxFd)

||| Add a source of completions: its `pollFd` is waited for with the others.
export
addSource : Scheduler -> Source -> IO (Either Errno ())
addSource = addSourceRaw

||| Start a task.
export
submit : Scheduler -> Task () -> IO ()
submit s t = run s s.root t (\_ => pure ())

||| The descriptor that is readable when a turn has something to do, to be
||| waited for by another `epoll`.
export
pollFd : Scheduler -> FileDesc
pollFd s = epollDescriptor s.master

||| Run the ready tasks, wait once at most `timeoutMs` milliseconds (negative:
||| until something happens) for the sources and the timers, and run what they
||| woke. `False` when nothing is left: no ready step, no timer, no operation
||| pending.
export
turn : Scheduler -> (timeoutMs : Int32) -> IO Bool
turn s timeoutMs = do
  q <- readIORef s.runQ
  runBatch s (Queue.length q)
  fireTimers s
  q' <- readIORef s.runQ
  pend <- readIORef s.pending
  if Queue.length q' == 0 && pend == 0
     then pure False
     else do
       limit <- waitTime s
       let wait = if timeoutMs < 0 then limit
                  else if limit < 0 then timeoutMs
                  else min timeoutMs limit
       Right evs <- epollWait s.master wait
         | Left _ => pure True
       srcs <- readIORef s.sources
       traverse_ (\ev => maybe (pure ()) (.drain) (lookup ev.fd srcs)) evs
       fireTimers s
       pure True

||| Run a task and everything it starts until nothing is left; its result,
||| `Nothing` if it never finished (it was `Empty`, or was cancelled).
export
runTask : Task a -> IO (Maybe a)
runTask t = do
  Right s <- newScheduler
    | Left _ => pure Nothing
  res <- newIORef Nothing
  submit s (Seq t (\a => Point (writeIORef res (Just a))))
  loop s
  closeScheduler s
  readIORef res
  where
    loop : Scheduler -> IO ()
    loop s = do
      more <- turn s (-1)
      when more (loop s)
