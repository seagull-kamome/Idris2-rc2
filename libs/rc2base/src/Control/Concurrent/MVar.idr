||| Haskell's `Control.Concurrent.MVar`: a mutable box that is also a
||| synchronisation primitive, built on `System.Concurrency`'s own
||| `Mutex`/`Condition` (`System.Concurrency.RC2` already wires those
||| onto real pthreads primitives under `--cg rc2`, so this module is
||| plain, backend-independent Idris throughout -- no `%foreign` of its
||| own). `takeMVar` blocks while empty; `putMVar` blocks while full;
||| an `MVar` is otherwise exactly one of the two at any instant, never
||| both, never neither.
|||
||| `modifyMVar`/`modifyMVar_`/`withMVar` only ever hold the internal
||| `Mutex` for this module's own short bookkeeping (checking/updating
||| `contents`, signalling) -- never across the caller-supplied action,
||| which they run with the `MVar` already taken (so `tryTakeMVar`/
||| `isEmptyMVar`/... from another thread see it as genuinely empty and
||| return immediately, never blocked on that action's own duration).
||| No exception safety of any kind: if the action itself raises
||| (however this backend's `io` does that) or otherwise never returns
||| normally, the `MVar` is left empty forever, same as any
||| `takeMVar` whose matching `putMVar` never runs -- GHC's own
||| `modifyMVar` additionally masks asynchronous exceptions and always
||| runs a matching `putMVar` via `bracket`; there is no portable
||| equivalent to build that on here.
|||
||| Calling `takeMVar`/`modifyMVar`/`withMVar`/... again for the *same*
||| `MVar` from inside one of these actions deadlocks (blocks forever
||| on a `Condition` nothing will ever signal) exactly the way it does
||| in Haskell -- this module has no way to detect that and diagnose it
||| up front.
module Control.Concurrent.MVar

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Data.IORef
import System.Concurrency

-- waitForFullLocked/waitForEmptyLocked's own recursion (looping back
-- around a blocking `conditionWait`) has no structurally-decreasing
-- argument for the termination checker to see -- genuinely open-ended
-- blocking is the point, not an oversight -- so this relaxes
-- rc2base.ipkg's package-wide `--total` to `covering`, the same way
-- System.IO.Epoll's own `readyEvents` already does.
%default covering

||| `contents = Nothing` is "empty", `Just x` is "full". `notFull`/
||| `notEmpty` are signalled on every transition out of the state a
||| blocked waiter is stuck on (full -> empty wakes a `putMVar`, empty
||| -> full wakes a `takeMVar`/`readMVar`).
export
record MVar a where
  constructor MkMVar
  mutex : Mutex
  notFull : Condition
  notEmpty : Condition
  contents : IORef (Maybe a)

-- Both assume `mv.mutex` is already held by the caller and leave it
-- held on return -- acquiring/releasing is always the caller's own
-- job, so it can fold further bookkeeping (a write, a signal) into
-- the same critical section before releasing.

waitForFullLocked : HasIO io => MVar a -> io a
waitForFullLocked mv = do
  Just x <- readIORef mv.contents
    | Nothing => do
        conditionWait mv.notEmpty mv.mutex
        waitForFullLocked mv
  pure x

waitForEmptyLocked : HasIO io => MVar a -> io ()
waitForEmptyLocked mv = do
  Nothing <- readIORef mv.contents
    | Just _ => do
        conditionWait mv.notFull mv.mutex
        waitForEmptyLocked mv
  pure ()

||| A fresh, empty `MVar`.
export
newEmptyMVar : HasIO io => io (MVar a)
newEmptyMVar = do
  mutex <- makeMutex
  notFull <- makeCondition
  notEmpty <- makeCondition
  contents <- newIORef Nothing
  pure (MkMVar mutex notFull notEmpty contents)

||| Takes the value out, leaving the `MVar` empty. Blocks while it's
||| already empty.
export
takeMVar : HasIO io => MVar a -> io a
takeMVar mv = do
  mutexAcquire mv.mutex
  x <- waitForFullLocked mv
  writeIORef mv.contents Nothing
  conditionSignal mv.notFull
  mutexRelease mv.mutex
  pure x

||| Puts `x` in, leaving the `MVar` full. Blocks while it's already
||| full.
export
putMVar : HasIO io => MVar a -> a -> io ()
putMVar mv x = do
  mutexAcquire mv.mutex
  waitForEmptyLocked mv
  writeIORef mv.contents (Just x)
  conditionSignal mv.notEmpty
  mutexRelease mv.mutex

||| A fresh `MVar`, already full with `x`.
export
newMVar : HasIO io => a -> io (MVar a)
newMVar x = do
  mv <- newEmptyMVar
  putMVar mv x
  pure mv

||| `Just` the value (leaving the `MVar` empty), or `Nothing` at once
||| if it's already empty -- never blocks.
export
tryTakeMVar : HasIO io => MVar a -> io (Maybe a)
tryTakeMVar mv = do
  mutexAcquire mv.mutex
  mx <- readIORef mv.contents
  case mx of
       Nothing => do
         mutexRelease mv.mutex
         pure Nothing
       Just x => do
         writeIORef mv.contents Nothing
         conditionSignal mv.notFull
         mutexRelease mv.mutex
         pure (Just x)

||| Puts `x` in and returns `True`, or does nothing and returns
||| `False` if the `MVar` is already full -- never blocks.
export
tryPutMVar : HasIO io => MVar a -> a -> io Bool
tryPutMVar mv x = do
  mutexAcquire mv.mutex
  mx <- readIORef mv.contents
  case mx of
       Just _ => do
         mutexRelease mv.mutex
         pure False
       Nothing => do
         writeIORef mv.contents (Just x)
         conditionSignal mv.notEmpty
         mutexRelease mv.mutex
         pure True

||| A snapshot of whether the `MVar` is currently empty -- stale the
||| instant another thread runs, same caveat as Haskell's own
||| `isEmptyMVar`.
export
isEmptyMVar : HasIO io => MVar a -> io Bool
isEmptyMVar mv = do
  mutexAcquire mv.mutex
  mx <- readIORef mv.contents
  mutexRelease mv.mutex
  pure (case mx of
             Nothing => True
             Just _  => False)

||| Reads the value without taking it -- blocks while empty, same as
||| `takeMVar`, but leaves the `MVar` full afterward. Held under one
||| single critical section (never released mid-wait the way
||| `takeMVar` followed by `putMVar` would be), so no concurrent
||| `takeMVar`/`putMVar` can ever interleave between the read and the
||| return -- what's read is always exactly what a concurrent
||| `takeMVar` would have gotten at that same instant.
export
readMVar : HasIO io => MVar a -> io a
readMVar mv = do
  mutexAcquire mv.mutex
  x <- waitForFullLocked mv
  mutexRelease mv.mutex
  pure x

||| Atomically replaces the value with `new`, returning the old one.
||| Blocks while empty. Same single-critical-section reasoning as
||| `readMVar` -- the fullness state never changes, so unlike
||| `takeMVar`/`putMVar` there is nothing to signal either.
export
swapMVar : HasIO io => MVar a -> a -> io a
swapMVar mv new = do
  mutexAcquire mv.mutex
  old <- waitForFullLocked mv
  writeIORef mv.contents (Just new)
  mutexRelease mv.mutex
  pure old

||| Takes the value, runs `f` on it with the `MVar` left empty for
||| everyone else, then puts `f`'s own result back. See this module's
||| own doc comment for the exception-safety and same-`MVar`-reentrancy
||| caveats this (like `modifyMVar`/`withMVar`) inherits from being
||| built out of a bare `takeMVar`+`putMVar` pair rather than one
||| primitive.
export
modifyMVar_ : HasIO io => MVar a -> (a -> io a) -> io ()
modifyMVar_ mv f = do
  x <- takeMVar mv
  x' <- f x
  putMVar mv x'

||| Like `modifyMVar_`, but `f` also returns an extra value threaded
||| back out as this function's own result -- the usual way to combine
||| an update with reading something out of it in one step.
export
modifyMVar : HasIO io => MVar a -> (a -> io (a, b)) -> io b
modifyMVar mv f = do
  x <- takeMVar mv
  (x', y) <- f x
  putMVar mv x'
  pure y

||| Takes the value, runs `f` on it (read-only intent -- `f`'s own
||| result is returned, the original value is put straight back
||| unchanged), leaving the `MVar` empty for everyone else for `f`'s
||| own duration. Same caveats as `modifyMVar_`.
export
withMVar : HasIO io => MVar a -> (a -> io b) -> io b
withMVar mv f = do
  x <- takeMVar mv
  y <- f x
  putMVar mv x
  pure y
