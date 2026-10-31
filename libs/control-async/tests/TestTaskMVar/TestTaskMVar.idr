module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Control.Task.MVar: a lock between tasks on four threads (runTaskParallel),
-- waiting to take and to put, the order of the line, and a wait or a
-- modification that is given up taking nothing and losing nothing.

import Control.Task
import Control.Task.MVar
import Control.Task.Scheduler
import Data.List
import Data.Maybe

%default covering

repeatT : Nat -> Task () -> Task ()
repeatT Z _ = pure ()
repeatT (S n) t = t *> repeatT n t

together : List (Task a) -> Task (List a)
together ts = traverse fork ts >>= traverse wait

lockTest : Task Nat
lockTest = do
  m <- newMVar (the Nat 0)
  _ <- together (replicate 8 (repeatT 100 (modifyMVar_ m (\n => liftIO (pure (S n))))))
  takeMVar m

-- The taker waits for a put that comes later.
waitTest : Task Nat
waitTest = do
  m <- newEmptyMVar
  taker <- fork (takeMVar m)
  sleepFor 20
  putMVar m (the Nat 42)
  wait taker

-- The tasks take in the order they started waiting.
lineTest : Task (List (Nat, Nat))
lineTest = do
  m <- newEmptyMVar
  takers <- traverse (\i => fork (sleepFor (5 * i) *> map (\v => (i, v)) (takeMVar m))) [0, 1, 2]
  sleepFor 40
  traverse_ (putMVar m) (the (List Nat) [10, 11, 12])
  traverse wait takers

-- A put into a full cell waits until it is emptied.
fullTest : Task (Nat, Nat)
fullTest = do
  m <- newMVar (the Nat 1)
  putter <- fork (putMVar m 2)
  sleepFor 20
  a <- takeMVar m
  _ <- wait putter
  b <- takeMVar m
  pure (a, b)

-- A take that lost a race is no longer waiting: the value is not swallowed.
givenUpTake : Task (Maybe Nat)
givenUpTake = do
  m <- newEmptyMVar
  _ <- race (takeMVar m) (sleepFor 20)
  putMVar m (the Nat 5)
  tryTakeMVar m

-- A modification that is given up leaves the old value in the cell.
givenUpModify : Task (Maybe Nat)
givenUpModify = do
  m <- newMVar (the Nat 7)
  _ <- race (modifyMVar_ m (\_ => empty)) (sleepFor 20)
  tryTakeMVar m

-- The value is handed to a take in the very step that makes it lose the race:
-- it goes back into the cell.
handedToLoser : Task (Maybe Nat, Maybe Nat)
handedToLoser = do
  m <- newEmptyMVar
  _ <- race (takeMVar m) (tryPutMVar m 5)
  a <- tryTakeMVar m
  _ <- race (modifyMVar_ m (\n => pure (n + 1))) (tryPutMVar m 3)
  b <- tryTakeMVar m
  pure (a, b)

main : IO ()
main = do
  r <- runTaskParallel 4 (do
         a <- lockTest
         b <- waitTest
         c <- lineTest
         d <- fullTest
         e <- givenUpTake
         f <- givenUpModify
         g <- handedToLoser
         pure [ "lock: " ++ show a
              , "wait: " ++ show b
              , "line: " ++ show c
              , "full: " ++ show d
              , "given-up take: " ++ show e
              , "given-up modify: " ++ show f
              , "handed to the loser: " ++ show g ])
  traverse_ putStrLn (fromMaybe ["no result"] r)
