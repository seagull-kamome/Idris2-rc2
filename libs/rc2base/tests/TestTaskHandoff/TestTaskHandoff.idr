module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Control.Task: handoff (a value handed to a task whose scope is cancelled
-- before it goes on is given back, not lost), finally (the action runs once,
-- when the task ends or is given up, from the step that starts it) and
-- spawnOwning (the action runs if the spawned task never starts).

import Control.Task
import Control.Task.Scheduler
import Data.IORef

%default covering

-- A one-place mailbox with at most one waiting receiver, to hand values over.
record Box where
  constructor MkBox
  waiter : IORef (Maybe (Nat -> IO ()))

newBox : IO Box
newBox = MkBox <$> newIORef Nothing

-- Give the value to the waiting receiver; whether there was one.
put : Box -> Nat -> IO Bool
put box v = do
  w <- readIORef box.waiter
  case w of
    Nothing => pure False
    Just done => do
      writeIORef box.waiter Nothing
      done v
      pure True

-- A receive that is given up does not leave the line.
stubbornReceive : Box -> (Env -> Completion Nat -> IO Cancel)
stubbornReceive box = \_, done => writeIORef box.waiter (Just done) *> pure noCancel

-- A receive that is given up leaves the line.
politeReceive : Box -> (Env -> Completion Nat -> IO Cancel)
politeReceive box = \_, done => do
  writeIORef box.waiter (Just done)
  pure (MkCancel (modifyIORef box.waiter (const Nothing)))

logTo : IORef (List String) -> String -> IO ()
logTo ref line = modifyIORef ref (line ::)

-- The receiver loses the race in the step that hands it the value: it is
-- given back.
handedOver : Task (List String)
handedOver = do
  ref <- onReactor (newIORef [])
  box <- onReactor newBox
  _ <- race (handoff (politeReceive box) (\v => logTo ref ("given back " ++ show v)))
            (onReactor (put box 2))
  onReactor (reverse <$> readIORef ref)

-- The operation is given up but still calls its completion later.
late : Task (List String)
late = do
  ref <- onReactor (newIORef [])
  box <- onReactor newBox
  _ <- race (handoff (stubbornReceive box) (\v => logTo ref ("late " ++ show v))) (sleepFor 10)
  _ <- onReactor (put box 3)
  onReactor (reverse <$> readIORef ref)

-- Where the value arrives in time, the task has it and nothing is given back.
delivered : Task (Nat, List String)
delivered = do
  ref <- onReactor (newIORef [])
  box <- onReactor newBox
  r <- fork (handoff (politeReceive box) (\v => logTo ref ("given back " ++ show v)))
  sleepFor 5
  _ <- onReactor (put box 4)
  v <- wait r
  log <- onReactor (readIORef ref)
  pure (v, log)

-- `finally`: once, with the result at the end, with Nothing when given up.
finallyTest : Task (List String)
finallyTest = do
  ref <- onReactor (newIORef [])
  let note = \r => logTo ref ("release " ++ show r)
  a <- finally note (pure (the Nat 1))
  _ <- race (finally note (sleepFor 1000 *> pure (the Nat 2))) (sleepFor 10)
  onReactor (reverse <$> readIORef ref)

-- `spawnOwning`: the task runs, or its release does.
ownedTest : Task (List String)
ownedTest = do
  ref <- onReactor (newIORef [])
  spawnOwning (logTo ref "released (root)") (liftIO (logTo ref "ran (root)"))
  _ <- race (spawnOwning (logTo ref "released (cancelled)") (liftIO (logTo ref "ran (cancelled)")))
            (sleepFor 1000)
  sleepFor 10
  onReactor (reverse <$> readIORef ref)

main : IO ()
main = do
  r <- runTask (do
         a <- handedOver
         b <- late
         c <- delivered
         d <- finallyTest
         e <- ownedTest
         pure [ "handed over: " ++ show a
              , "late completion: " ++ show b
              , "delivered: " ++ show c
              , "finally: " ++ show d
              , "owned: " ++ show e ])
  traverse_ putStrLn (maybe ["no result"] id r)
