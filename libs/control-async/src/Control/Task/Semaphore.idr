||| A counting semaphore for tasks: `acquireN` takes permits, waiting -- without
||| holding a thread -- while there are fewer than it needs; `releaseN` gives
||| them back. Waiting tasks are served in the order they came, and a task
||| that needs more permits than are free holds up the ones behind it. A wait
||| that is given up (a lost `race`, a cancelled scope) leaves the line and
||| takes nothing; permits handed to a task that is given up before it goes on
||| are released again. A task that asks for more than will ever be released
||| holds up the line until the total is raised or it gives up. Asking for 0
||| takes nothing but still waits its turn.
|||
||| Like the other primitives of this package it belongs to one scheduler, and
||| is touched only from tasks.
module Control.Task.Semaphore

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Control.Task
import Control.Task.Waiters
import Data.IORef

%default covering

-- All of it is touched on the thread of the scheduler only.
record State where
  constructor MkState
  permits : Nat
  line : Waiters (Nat, Completion ())

export
record Semaphore where
  constructor MkSemaphore
  state : IORef State

export
newSemaphoreIO : (permits : Nat) -> IO Semaphore
newSemaphoreIO n = MkSemaphore <$> newIORef (MkState n none)

export
newSemaphore : (permits : Nat) -> Task Semaphore
newSemaphore n = onReactor (newSemaphoreIO n)

-- Serve the front of the line while it can be.
serve : Nat -> Waiters (Nat, Completion ()) -> (Nat, Waiters (Nat, Completion ()), List (Completion ()))
serve permits line = case front line of
  Just ((need, done), rest) =>
    if need <= permits
       then let (p, l, ds) = serve (minus permits need) rest in (p, l, done :: ds)
       else (permits, line, [])
  Nothing => (permits, line, [])

-- Settle the state, then wake the tasks that got their permits.
settle : Semaphore -> Nat -> Waiters (Nat, Completion ()) -> IO ()
settle s permits line = do
  let (p, l, woken) = serve permits line
  writeIORef s.state (MkState p l)
  traverse_ (\done => done ()) woken

releaseNow : Semaphore -> Nat -> IO ()
releaseNow s n = do
  st <- readIORef s.state
  settle s (st.permits + n) st.line

takeIfFree : Semaphore -> Nat -> IO Bool
takeIfFree s n = do
  st <- readIORef s.state
  case front st.line of
    Nothing =>
      if n <= st.permits
         then True <$ writeIORef s.state ({ permits := minus st.permits n } st)
         else pure False
    Just _ => pure False

acquireOrWait : Semaphore -> Nat -> Completion () -> IO (Maybe Nat)
acquireOrWait s n done = do
  ok <- takeIfFree s n
  if ok
     then Nothing <$ done ()
     else do
       st <- readIORef s.state
       let (k, line') = enter (n, done) st.line
       writeIORef s.state ({ line := line' } st)
       pure (Just k)

leaveLine : Semaphore -> Nat -> Cancel
leaveLine s k = MkCancel $ do
  st <- readIORef s.state
  settle s st.permits (leave k st.line)

||| Take `n` permits, waiting until that many are free.
export
acquireN : Semaphore -> Nat -> Task ()
acquireN s n =
  handoff (\_, done => maybe noCancel (leaveLine s) <$> acquireOrWait s n done) (\_ => releaseNow s n)

||| Take one permit.
export
acquire : Semaphore -> Task ()
acquire s = acquireN s 1

||| Give `n` permits back (or add new ones).
export
releaseN : Semaphore -> Nat -> Task ()
releaseN s n = onReactor (releaseNow s n)

||| Give one permit back.
export
release : Semaphore -> Task ()
release s = releaseN s 1

||| Take `n` permits if they are free and nobody is waiting, without waiting.
export
tryAcquireN : Semaphore -> Nat -> Task Bool
tryAcquireN s n = onReactor (takeIfFree s n)

||| Take one permit if it is free, without waiting.
export
tryAcquire : Semaphore -> Task Bool
tryAcquire s = tryAcquireN s 1

||| The permits that are free now.
export
available : Semaphore -> Task Nat
available s = onReactor (permits <$> readIORef s.state)

||| Run the task holding `n` permits. They are given back when it ends or is
||| given up. An action of the task that has started on a worker thread runs on
||| after the give-up, so for that long more than the permits can be running.
export
withPermits : Semaphore -> Nat -> Task a -> Task a
withPermits s n body = acquireN s n >>= \_ => finally (\_ => releaseNow s n) body

||| Run the task holding one permit.
export
withPermit : Semaphore -> Task a -> Task a
withPermit s = withPermits s 1
