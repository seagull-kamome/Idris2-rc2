module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Control.Task.Chan: a producer and three consumers on four threads
-- (runTaskParallel) through a channel of two, close, and the waits that are
-- given up.

import Control.Task
import Control.Task.Chan
import Control.Task.Ref
import Control.Task.Scheduler
import Data.Maybe

%default covering

together : List (Task a) -> Task (List a)
together ts = traverse fork ts >>= traverse wait

-- Receive until the channel is closed and empty; how many values it got.
consume : Chan Nat -> Ref Nat -> Ref Nat -> Task Nat
consume ch sum seen = do
  Just v <- recv ch
    | Nothing => pure 0
  modifyRef sum (+ v)
  modifyRef seen S
  S <$> consume ch sum seen

pipeline : Task (Nat, Nat, Nat)
pipeline = do
  ch <- newChan 2
  sum <- newRef (the Nat 0)
  seen <- newRef (the Nat 0)
  consumers <- traverse (\_ => fork (consume ch sum seen)) [1, 2, 3]
  producer <- fork (traverse_ (send ch) [1 .. 50] *> close ch)
  _ <- wait producer
  counts <- traverse wait consumers
  (,,) <$> readRef sum <*> readRef seen <*> pure (addUp counts)
  where
    addUp : List Nat -> Nat
    addUp = foldr (+) 0

-- Full, closed, drained.
edges : Task (Bool, Bool, Maybe Nat, Maybe Nat, Bool, Maybe (Maybe Nat))
edges = do
  ch <- newChan 1
  a <- trySend ch (the Nat 1)
  b <- trySend ch 2
  c <- tryRecv ch
  _ <- send ch 3
  close ch
  d <- send ch 4
  e <- recv ch
  f <- recv ch
  pure (a, b, c, e, d, Just f)

-- A receive that lost a race is no longer waiting: the value is not swallowed.
givenUp : Task (Maybe Nat)
givenUp = do
  ch <- newChan 1
  _ <- race (recv ch) (sleepFor 20)
  _ <- send ch (the Nat 9)
  tryRecv ch

-- Closing wakes a receiver that was waiting.
closeWakes : Task (Maybe Nat)
closeWakes = do
  ch <- newChan 1
  r <- fork (recv ch)
  sleepFor 20
  close ch
  wait r

-- The value is handed to a receive in the very step that makes it lose the race:
-- it goes back into the channel.
handedToLoser : Task (Maybe Nat)
handedToLoser = do
  ch <- newChan 1
  _ <- race (recv ch) (trySend ch (the Nat 9))
  tryRecv ch

main : IO ()
main = do
  r <- runTaskParallel 4 (do
         a <- pipeline
         b <- edges
         c <- givenUp
         d <- closeWakes
         e <- handedToLoser
         pure [ "pipeline (sum, seen, received): " ++ show a
              , "edges: " ++ show b
              , "given-up recv: " ++ show c
              , "close wakes: " ++ show d
              , "handed to the loser: " ++ show e ])
  traverse_ putStrLn (fromMaybe ["no result"] r)
