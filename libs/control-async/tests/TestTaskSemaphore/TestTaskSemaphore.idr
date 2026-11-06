module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Control.Task.Semaphore: at most the permits run at once (tasks on four
-- threads, runTaskParallel), a wait for a release, the order of the line (a
-- task that needs more holds up the ones behind it), try versions, and a
-- wait or a holder that is given up losing no permit.

import Control.Task
import Control.Task.Ref
import Control.Task.Scheduler
import Control.Task.Semaphore
import Data.List

%default covering

together : List (Task a) -> Task (List a)
together ts = traverse fork ts >>= traverse wait

limitTest : Task (Nat, Nat)
limitTest = do
  s <- newSemaphore 3
  active <- newRef (the Nat 0)
  peak <- newRef (the Nat 0)
  let job = withPermit s $ do
        n <- atomicModifyRef active (\n => (S n, S n))
        modifyRef peak (max n)
        sleepFor 5
        modifyRef active (\n => minus n 1)
  _ <- together (replicate 12 job)
  (,) <$> readRef peak <*> available s

waitTest : Task Nat
waitTest = do
  s <- newSemaphore 0
  waiter <- fork (acquire s *> available s)
  sleepFor 20
  releaseN s 2
  wait waiter

lineTest : Task (List String)
lineTest = do
  s <- newSemaphore 0
  order <- newRef (the (List String) [])
  let note = \x => modifyRef order (++ [x])
  a <- fork (acquireN s 2 *> note "A")
  sleepFor 5
  b <- fork (acquire s *> note "B")
  sleepFor 5
  release s
  sleepFor 20
  early <- readRef order
  release s
  _ <- wait a
  release s
  _ <- wait b
  late <- readRef order
  pure (("served before A: " ++ show (length early)) :: late)

tryTest : Task (Bool, Bool, Nat)
tryTest = do
  s <- newSemaphore 1
  x <- tryAcquire s
  y <- tryAcquire s
  n <- available s
  pure (x, y, n)

givenUpWait : Task (Bool, Nat)
givenUpWait = do
  s <- newSemaphore 0
  r <- race (acquire s) (sleepFor 10)
  release s
  n <- available s
  pure (either (const True) (const False) r, n)

givenUpHolder : Task Nat
givenUpHolder = do
  s <- newSemaphore 1
  _ <- race (withPermit s (sleepFor 1000)) (sleepFor 10)
  available s

-- A task that needs more than is free holds up the one behind it (and try says
-- no although a permit is free), until it gives up.
headTest : Task (Bool, Bool, Nat)
headTest = do
  s <- newSemaphore 1
  big <- fork (race (acquireN s 2) (sleepFor 30))
  sleepFor 5
  small <- fork (acquire s *> available s)
  sleepFor 5
  tried <- tryAcquire s
  n <- available s
  early <- race (wait small) (sleepFor 5)
  _ <- wait big
  left <- wait small
  pure (either (const True) (const False) early, tried, left + n)

-- Several permits at once, and none at all.
manyTest : Task (Nat, Nat, Nat)
manyTest = do
  s <- newSemaphore 2
  acquireN s 0
  inside <- withPermits s 2 (available s)
  after <- available s
  releaseN s 0
  more <- available s
  pure (inside, after, more)

main : IO ()
main = do
  r <- runTaskParallel 4 (do
         (peak, free) <- limitTest
         b <- waitTest
         c <- lineTest
         d <- tryTest
         e <- givenUpWait
         f <- givenUpHolder
         g <- headTest
         h <- manyTest
         pure [ "limit: peak<=3 " ++ show (peak <= 3) ++ ", peak>=2 " ++ show (peak >= 2) ++ ", free " ++ show free
              , "wait: " ++ show b
              , "line: " ++ show c
              , "try: " ++ show d
              , "given-up wait: " ++ show e
              , "given-up holder: " ++ show f
              , "head: " ++ show g
              , "many: " ++ show h ])
  traverse_ putStrLn (maybe ["no result"] id r)
