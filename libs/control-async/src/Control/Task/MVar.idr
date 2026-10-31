||| A cell that holds a value or is empty, for tasks: taking from an empty one,
||| or putting into a full one, makes the task wait -- without holding a thread
||| -- until another task makes it possible. Waiting tasks are served in the
||| order they came. A wait that is given up (a lost `race`, a cancelled scope)
||| leaves the line and takes nothing; a value that was handed to a take whose
||| task is given up before it goes on goes back into the cell.
||| (`Control.Concurrent.MVar` is the one for threads, which blocks the thread.)
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

-- The cell was full and has been emptied: the first task waiting to put goes in.
refill : MVar a -> Waiters (a, Completion ()) -> IO ()
refill m putters = case front putters of
  Nothing => writeIORef m.state (Vacant none)
  Just ((v, accepted), rest) => writeIORef m.state (Holding v rest) *> accepted ()

-- A value arrives in the empty cell: the first task waiting to take gets it,
-- else it stays.
deliver : MVar a -> a -> Waiters (Completion a) -> IO ()
deliver m v takers = case front takers of
  Nothing => writeIORef m.state (Holding v none)
  Just (taker, rest) => writeIORef m.state (Vacant rest) *> taker v

-- Take the value if there is one.
tryTakeNow : MVar a -> IO (Maybe a)
tryTakeNow m = readIORef m.state >>= \st => case st of
  Vacant _ => pure Nothing
  Holding x putters => Just x <$ refill m putters

-- Put the value if the cell is empty.
tryPutNow : MVar a -> a -> IO Bool
tryPutNow m v = readIORef m.state >>= \st => case st of
  Holding _ _ => pure False
  Vacant takers => True <$ deliver m v takers

-- Take the value, or join the line of takers (its number is the result).
takeOrWait : MVar a -> Completion a -> IO (Maybe Nat)
takeOrWait m done = readIORef m.state >>= \st => case st of
  Vacant takers => do
    let (k, takers') = enter done takers
    writeIORef m.state (Vacant takers')
    pure (Just k)
  Holding x putters => do
    refill m putters
    Nothing <$ done x

-- Put the value, or join the line of putters.
putOrWait : MVar a -> a -> Completion () -> IO (Maybe Nat)
putOrWait m v done = readIORef m.state >>= \st => case st of
  Vacant takers => do
    deliver m v takers
    Nothing <$ done ()
  Holding x putters => do
    let (k, putters') = enter (v, done) putters
    writeIORef m.state (Holding x putters')
    pure (Just k)

-- Put the value; if the cell is full, wait in line with no task behind.
putAnyhow : MVar a -> a -> IO ()
putAnyhow m v = ignore (putOrWait m v (\_ => pure ()))

-- Leave the line of takers, or of putters.
leaveTakers, leavePutters : MVar a -> Nat -> Cancel
leaveTakers m k = MkCancel $ modifyIORef m.state $ \case
  Vacant takers => Vacant (leave k takers)
  other => other
leavePutters m k = MkCancel $ modifyIORef m.state $ \case
  Holding x putters => Holding x (leave k putters)
  other => other

||| Take the value, waiting while the cell is empty. A value handed to a task
||| that is given up before it goes on with it goes back into the cell.
export
takeMVar : MVar a -> Task a
takeMVar m = handoff (\_, done => maybe noCancel (leaveTakers m) <$> takeOrWait m done) (putAnyhow m)

||| Put a value, waiting while the cell is full.
export
putMVar : MVar a -> a -> Task ()
putMVar m v = Async $ \_, done => maybe noCancel (leavePutters m) <$> putOrWait m v done

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
modifyMVar m body =
  map snd $ takeMVar m >>= \old =>
    finally (\r => putAnyhow m (maybe old fst r)) (body old)

export
modifyMVar_ : MVar a -> (a -> Task a) -> Task ()
modifyMVar_ m body = modifyMVar m (\a => (\a' => (a', ())) <$> body a)

||| Run `body` on the value while holding the cell.
export
withMVar : MVar a -> (a -> Task b) -> Task b
withMVar m body = modifyMVar m (\a => (\b => (a, b)) <$> body a)
