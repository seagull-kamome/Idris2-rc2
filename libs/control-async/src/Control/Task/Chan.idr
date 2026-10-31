||| A queue of bounded length that tasks send values into and receive values
||| from. A task that receives from an empty channel, or sends into a full one,
||| waits -- without holding a thread -- and waiting tasks are served in the
||| order they came. A wait that is given up leaves the line; a value that was
||| handed to a receive whose task is given up before it goes on goes back into
||| the channel. A channel can be closed: what is in it can still be received,
||| and then `recv` gives `Nothing`.
module Control.Task.Chan

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Control.Task
import Control.Task.Waiters
import Data.IORef
import Data.Queue

%default covering

-- All of it is touched on the thread of the scheduler only.
record State a where
  constructor MkState
  items : Queue a
  count : Nat
  closed : Bool
  ||| Tasks waiting for a value; only while `items` is empty.
  takers : Waiters (Completion (Maybe a))
  ||| Tasks waiting for room; only while `items` is full.
  senders : Waiters (a, Completion Bool)

export
record Chan a where
  constructor MkChan
  capacity : Nat
  state : IORef (State a)

||| A channel that holds up to `capacity` values (at least 1).
export
newChanIO : (capacity : Nat) -> IO (Chan a)
newChanIO capacity =
  MkChan (max 1 capacity) <$> newIORef (MkState empty 0 False none none)

export
newChan : (capacity : Nat) -> Task (Chan a)
newChan capacity = onReactor (newChanIO capacity)

-- The next value, if there is one; the first task waiting to send moves in.
tryRecvNow : Chan a -> IO (Maybe a)
tryRecvNow ch = do
  st <- readIORef ch.state
  case dequeue st.items of
    Nothing => pure Nothing
    Just (x, rest) => do
      case front st.senders of
        Nothing => writeIORef ch.state ({ items := rest, count := minus st.count 1 } st)
        Just ((v, sent), senders') => do
          writeIORef ch.state ({ items := enqueue v rest, senders := senders' } st)
          sent True
      pure (Just x)

-- `Nothing` if the value cannot go in now (the channel is full), else whether
-- it went in (`False`: the channel is closed).
trySendNow : Chan a -> a -> IO (Maybe Bool)
trySendNow ch v = do
  st <- readIORef ch.state
  if st.closed then pure (Just False) else
    case front st.takers of
      Just (taker, takers') => do
        writeIORef ch.state ({ takers := takers' } st)
        taker (Just v)
        pure (Just True)
      Nothing =>
        if st.count < ch.capacity
          then do writeIORef ch.state ({ items := enqueue v st.items, count := S st.count } st)
                  pure (Just True)
          else pure Nothing

-- Take back a value that was handed to a receiver that never went on with it:
-- to the first task waiting to receive, else to the front of the channel (which
-- can then hold one more than its capacity until a value is received).
giveBack : Chan a -> a -> IO ()
giveBack ch v = do
  st <- readIORef ch.state
  case front st.takers of
    Just (taker, takers') => do
      writeIORef ch.state ({ takers := takers' } st)
      taker (Just v)
    Nothing =>
      writeIORef ch.state ({ items := fromList (v :: toList st.items), count := S st.count } st)

||| The next value, waiting while there is none. `Nothing`: the channel is
||| closed and empty. A value handed to a task that is given up before it goes on
||| with it goes back into the channel.
export
recv : Chan a -> Task (Maybe a)
recv ch = handoff (\_, done => do
  r <- tryRecvNow ch
  case r of
    Just x => noCancel <$ done (Just x)
    Nothing => do
      st <- readIORef ch.state
      if st.closed then noCancel <$ done Nothing else do
        let (k, takers') = enter done st.takers
        writeIORef ch.state ({ takers := takers' } st)
        pure (MkCancel (modifyIORef ch.state { takers $= leave k }))) (traverse_ (giveBack ch))

||| Send a value, waiting while the channel is full. `False`: the channel is
||| closed, and the value went nowhere.
export
send : Chan a -> a -> Task Bool
send ch v = Async $ \_, done => do
  r <- trySendNow ch v
  case r of
    Just ok => noCancel <$ done ok
    Nothing => do
      st <- readIORef ch.state
      let (k, senders') = enter (v, done) st.senders
      writeIORef ch.state ({ senders := senders' } st)
      pure (MkCancel (modifyIORef ch.state { senders $= leave k }))

||| The next value if there is one, without waiting.
export
tryRecv : Chan a -> Task (Maybe a)
tryRecv ch = onReactor (tryRecvNow ch)

||| Send if there is room, without waiting; whether the value went in.
export
trySend : Chan a -> a -> Task Bool
trySend ch v = onReactor (map (== Just True) (trySendNow ch v))

||| Close the channel. What is in it can still be received; the tasks waiting to
||| receive are told there is nothing more, and those waiting to send are told
||| their value went nowhere. Closing twice does nothing more.
export
close : Chan a -> Task ()
close ch = onReactor $ do
  st <- readIORef ch.state
  let (takers, noTakers) = everyone st.takers
  let (senders, noSenders) = everyone st.senders
  writeIORef ch.state ({ closed := True, takers := noTakers, senders := noSenders } st)
  traverse_ (\t => t Nothing) takers
  traverse_ (\s => snd s False) senders
