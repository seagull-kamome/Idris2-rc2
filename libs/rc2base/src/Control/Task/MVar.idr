||| A cell that holds a value or is empty, for tasks: taking from an empty one,
||| or putting into a full one, makes the task wait -- without holding a thread
||| -- until another task makes it possible. Waiting tasks are served in the
||| order they came. A wait that is given up (a lost `race`, a cancelled scope)
||| leaves the line, and takes nothing. (`Control.Concurrent.MVar` is the one
||| for threads, which blocks the thread.)
module Control.Task.MVar

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Control.Task
import Control.Task.Waiters
import Data.IORef

%default covering

-- All of it is touched on the thread of the scheduler only.
data State a
  = Vacant (Waiters (Completion a))
  | Holding a (Waiters (a, Completion ()))

export
record MVar a where
  constructor MkMVar
  state : IORef (State a)

export
newEmptyMVarIO : IO (MVar a)
newEmptyMVarIO = MkMVar <$> newIORef (Vacant none)

export
newMVarIO : a -> IO (MVar a)
newMVarIO x = MkMVar <$> newIORef (Holding x none)

export
newEmptyMVar : Task (MVar a)
newEmptyMVar = onReactor newEmptyMVarIO

export
newMVar : a -> Task (MVar a)
newMVar x = onReactor (newMVarIO x)

-- Take the value if there is one; the first task waiting to put goes in.
tryTakeNow : MVar a -> IO (Maybe a)
tryTakeNow m = do
  st <- readIORef m.state
  case st of
    Vacant _ => pure Nothing
    Holding x putters => do
      case front putters of
        Nothing => writeIORef m.state (Vacant none)
        Just ((v, accepted), rest) => do
          writeIORef m.state (Holding v rest)
          accepted ()
      pure (Just x)

-- Put the value if the cell is empty; the first task waiting to take gets it.
tryPutNow : MVar a -> a -> IO Bool
tryPutNow m v = do
  st <- readIORef m.state
  case st of
    Holding _ _ => pure False
    Vacant takers => do
      case front takers of
        Nothing => writeIORef m.state (Holding v none)
        Just (taker, rest) => do
          writeIORef m.state (Vacant rest)
          taker v
      pure True

-- Put the value, and if the cell is full wait in line without a task behind.
putAnyhow : MVar a -> a -> IO ()
putAnyhow m v = do
  ok <- tryPutNow m v
  unless ok $ do
    Holding x putters <- readIORef m.state
      | Vacant _ => pure ()
    writeIORef m.state (Holding x (snd (enter (v, \_ => pure ()) putters)))

||| Take the value, waiting while the cell is empty.
export
takeMVar : MVar a -> Task a
takeMVar m = Async $ \_, done => do
  r <- tryTakeNow m
  case r of
    Just v => done v *> pure noCancel
    Nothing => do
      Vacant takers <- readIORef m.state
        | Holding _ _ => pure noCancel
      let (k, takers') = enter done takers
      writeIORef m.state (Vacant takers')
      pure (MkCancel (modifyIORef m.state (\st => case st of
                                                    Vacant ts => Vacant (leave k ts)
                                                    other => other)))

||| Put a value, waiting while the cell is full.
export
putMVar : MVar a -> a -> Task ()
putMVar m v = Async $ \_, done => do
  ok <- tryPutNow m v
  if ok then done () *> pure noCancel else do
    Holding x putters <- readIORef m.state
      | Vacant _ => pure noCancel
    let (k, putters') = enter (v, done) putters
    writeIORef m.state (Holding x putters')
    pure (MkCancel (modifyIORef m.state (\st => case st of
                                                  Holding y ps => Holding y (leave k ps)
                                                  other => other)))

||| Take the value if there is one, without waiting.
export
tryTakeMVar : MVar a -> Task (Maybe a)
tryTakeMVar m = onReactor (tryTakeNow m)

||| Put the value if the cell is empty, without waiting; whether it was.
export
tryPutMVar : MVar a -> a -> Task Bool
tryPutMVar m v = onReactor (tryPutNow m v)

||| Run `body` with the value taken out of the cell, and put back what it gives.
||| The cell is empty meanwhile, which makes this a lock. If the task is given
||| up before it ends, the old value goes back: the cell is never left empty.
export
modifyMVar : MVar a -> (a -> Task (a, b)) -> Task b
modifyMVar m body = do
  old <- takeMVar m
  guard <- onReactor (newIORef (pure ()))
  spawn (Async (\_, done =>
    writeIORef guard (done ()) *> pure (MkCancel (putAnyhow m old))))
  (new, result) <- body old
  -- the sentinel ends and the new value goes in as one step, so a cancellation
  -- cannot restore the old value over it
  onReactor (join (readIORef guard) *> putAnyhow m new)
  pure result

export
modifyMVar_ : MVar a -> (a -> Task a) -> Task ()
modifyMVar_ m body = modifyMVar m (\a => (\a' => (a', ())) <$> body a)

||| Run `body` on the value while holding the cell.
export
withMVar : MVar a -> (a -> Task b) -> Task b
withMVar m body = modifyMVar m (\a => (\b => (a, b)) <$> body a)
