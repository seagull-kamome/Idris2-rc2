module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- `>>=` keeps a `Point` and its continuation together (`PointThen`), so that in
-- parallel mode a worker runs a chain of `liftIO`s without going back to the
-- scheduler between them: the same results, the same order of effects, in every
-- mode; a chain longer than the worker's limit goes on; what is not a `Point`
-- (`onReactor`, `both`, `race`) in the middle of a chain still works; and a
-- loop of `liftIO`s can still be given up.

import Control.Task
import Control.Task.Scheduler
import Data.IORef
import Data.List
import Data.Maybe
import System

%default covering

-- Four actions in a row, each using the result of the one before.
chained : IORef (List String) -> Task (Nat, Nat, Nat)
chained l = do
  x <- liftIO (modifyIORef l ("a" ::) *> pure 1)
  y <- liftIO (modifyIORef l ("b" ::) *> pure (x + 1))
  z <- liftIO (modifyIORef l ("c" ::) *> pure (y * 10))
  liftIO (modifyIORef l ("d" ::))
  pure (x, y, z)

-- `n` actions in a row.
counting : IORef Nat -> Nat -> Task ()
counting c Z = pure ()
counting c (S n) = liftIO (modifyIORef c (+ 1)) *> counting c n

-- A point, the reactor, a point, `map`, a point.
mixed : IORef (List String) -> Task Nat
mixed l = do
  a <- liftIO (modifyIORef l ("p1" ::) *> pure 1)
  b <- onReactor (modifyIORef l ("r" ::) *> pure (a + 1))
  c <- map (+ 100) (liftIO (modifyIORef l ("p2" ::) *> pure (b + 1)))
  liftIO (modifyIORef l ("p3" ::) *> pure (c + 1))

-- Points, then tasks that run together and race.
branching : Task (Nat, Nat)
branching = do
  a <- liftIO (pure (the Nat 2))
  (x, y) <- both (liftIO (pure (a * 3))) (liftIO (pure (a * 5)))
  r <- race (sleepFor 500 *> pure (the Nat 0)) (liftIO (pure (x + y)))
  pure (either id id r, a)

-- Never ends: a loop of points.
spin : IORef Nat -> Task ()
spin c = liftIO (modifyIORef c (+ 1)) >>= \_ => spin c

-- `finally` in the middle of a chain, then the chain goes on.
withFinally : IORef (List String) -> Task Nat
withFinally l = do
  a <- liftIO (modifyIORef l ("before" ::) *> pure 1)
  b <- finally (\r => modifyIORef l (("released " ++ show r) ::)) (liftIO (pure (a + 1)))
  liftIO (modifyIORef l ("after" ::) *> pure (b + 1))

-- A chain of `n` points on three threads: how many ran.
chainOf : Nat -> IO ()
chainOf n = do
  c <- newIORef 0
  _ <- runTaskParallel 3 (counting c n)
  k <- readIORef c
  putStrLn ("chain of " ++ show n ++ ": " ++ show k)

report : String -> IORef (List String) -> IO ()
report name l = readIORef l >>= \xs => putStrLn (name ++ " effects: " ++ show (reverse xs))

main : IO ()
main = do
  -- the same in every mode
  l1 <- newIORef []
  r1 <- runTask (chained l1)
  putStrLn ("one thread: " ++ show r1)
  report "one thread" l1
  l2 <- newIORef []
  r2 <- runTaskParallel 3 (chained l2)
  putStrLn ("three threads: " ++ show r2)
  report "three threads" l2
  l3 <- newIORef []
  (r3, _) <- runTaskVirtual (chained l3)
  putStrLn ("virtual clock: " ++ show r3)
  report "virtual clock" l3
  -- longer than a worker goes on without the scheduler
  c1 <- newIORef 0
  r4 <- runTaskParallel 3 (counting c1 1000)
  n1 <- readIORef c1
  putStrLn ("a chain of 1000: " ++ show r4 ++ ", counted " ++ show n1)
  -- what is not a point in the middle
  l4 <- newIORef []
  r5 <- runTaskParallel 3 (mixed l4)
  putStrLn ("mixed: " ++ show r5)
  report "mixed" l4
  r6 <- runTaskParallel 3 branching
  putStrLn ("branching, three threads: " ++ show r6)
  r7 <- runTask branching
  putStrLn ("branching, one thread: " ++ show r7)
  -- `map` of a chain
  r8 <- runTaskParallel 3 (map (+ 1000) (liftIO (pure (the Nat 1)) >>= \x => liftIO (pure (x + 1))))
  putStrLn ("map of a chain: " ++ show r8)
  -- the length of the worker's run does not matter
  traverse_ chainOf [63, 64, 65, 128, 129]
  -- many steps with `*>`: the time does not grow with the square of the number
  c3 <- newIORef 0
  _ <- runTaskParallel 3 (counting c3 100000)
  _ <- runTask (counting c3 100000)
  readIORef c3 >>= \k => putStrLn ("two loops of 100000: " ++ show k)
  -- `>>=` on the left, and `finally` in the middle
  r10 <- runTaskParallel 3 (((liftIO (pure (the Nat 1)) >>= \x => liftIO (pure (x + 1))) >>= \y => liftIO (pure (y * 10))) >>= \z => pure (z + 5))
  putStrLn ("bind on the left: " ++ show r10)
  l5 <- newIORef []
  r11 <- runTaskParallel 3 (withFinally l5)
  putStrLn ("finally in a chain: " ++ show r11)
  report "finally" l5
  -- a loop of points is given up, and stops
  c2 <- newIORef 0
  l6 <- newIORef []
  r9 <- runTaskParallel 3 (race (finally (\r => modifyIORef l6 (("released " ++ show (isJust r)) ::)) (spin c2)) (sleepFor 50))
  n2 <- readIORef c2
  usleep 100000
  n3 <- readIORef c2
  putStrLn ("loop given up: " ++ show (isJust r9) ++ ", ran " ++ show (n2 > 0) ++ ", stopped " ++ show (n2 == n3))
  report "given up" l6
