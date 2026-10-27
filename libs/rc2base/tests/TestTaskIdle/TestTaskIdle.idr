module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Control.Task.Scheduler used from outside, as a program that waits for
-- `pollFd` with its own epoll does (termui): once every task has ended and
-- `turn` says nothing is left, `pollFd` must not be readable. A wake-up that
-- is left behind makes that program call `turn` again at once, for ever, and
-- use a whole core while it is idle.

import Control.Task
import Control.Task.Scheduler
import Data.IORef
import System.Linux.Epoll
import System.Posix.Errno

%default covering

-- Wait for `pollFd` and call `turn` the way such a program does, until the task
-- has ended and `pollFd` is quiet, at most `fuel` times. The number of calls to
-- `turn` and whether `pollFd` is still readable.
drive : Scheduler -> EPoll -> IO Bool -> Nat -> IO (Nat, Bool)
drive s ep done fuel = go fuel 0
  where
    ready : Int32 -> IO Bool
    ready wait = do
      r <- epollWait ep wait
      pure (case r of
              Right (_ :: _) => True
              _ => False)

    go : Nat -> Nat -> IO (Nat, Bool)
    go Z n = (n,) <$> ready 0
    go (S k) n = do
      d <- done
      r <- ready (if d then 0 else 200)
      if r then turn s 0 *> go k (S n)
           else if d then pure (n, False) else go k n

check : String -> (IORef Bool -> Task ()) -> IO ()
check title mk = do
  Right s <- newScheduler
    | Left _ => putStrLn (title ++ ": no scheduler")
  Right ep <- epollCreate 4
    | Left _ => putStrLn (title ++ ": no epoll")
  Right () <- epollAdd ep (pollFd s) EPOLLIN
    | Left _ => putStrLn (title ++ ": epollAdd failed")
  flag <- newIORef False
  submit s (mk flag)
  (n, still) <- drive s ep (readIORef flag) 50
  ended <- readIORef flag
  putStrLn (title ++ ": ended " ++ show ended ++ ", calls to turn " ++ (if n <= 10 then "few" else "MANY") ++ ", pollFd still readable: " ++ show still)
  closeScheduler s

main : IO ()
main = do
  check "a task that ends at once" (\f => liftIO (writeIORef f True))
  check "a task that sleeps" (\f => sleepFor 5 *> liftIO (writeIORef f True))
  check "a task that starts another" (\f => spawn (sleepFor 3) *> sleepFor 2 *> liftIO (writeIORef f True))
