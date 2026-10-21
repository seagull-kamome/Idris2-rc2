module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Control.Task's Env.slot (one value per scheduler, released when it is
-- closed) and Env.addSource (a source of completions added by an Async, taken
-- out again when the Async is given up).

import Control.Task
import Control.Task.Scheduler
import Control.Task.Source
import Data.Bits
import Data.IORef
import System.Linux.Eventfd
import System.Posix.Errno
import System.Posix.FileDesc

%default covering

-- The value under `key`, made (and counted in `made`) on the first call.
slotValue : IORef Nat -> IORef (List String) -> String -> Nat -> Task (Either Errno Nat)
slotValue made released key v = Async $ \env, done => do
  r <- env.slot key (modifyIORef made S *> pure (Right (v, modifyIORef released (key ::))))
  done r
  pure noCancel

showEither : Either Errno Nat -> String
showEither = either show show

slotTest : IO ()
slotTest = do
  made <- newIORef 0
  released <- newIORef []
  r <- runTask (do a <- slotValue made released "x" 7
                   b <- slotValue made released "x" 99
                   c <- slotValue made released "y" 1
                   pure (map showEither [a, b, c]))
  putStrLn ("values: " ++ show r)
  n <- readIORef made
  putStrLn ("made: " ++ show n)
  l <- readIORef released
  putStrLn ("released at close: " ++ show l)

-- Registers a source on `efd` that counts its drains, and (with `fires`)
-- completes the operation from `drain`.
sourceOp : FileDesc -> IORef Nat -> (fires : Bool) -> Task String
sourceOp efd drains fires = Async $ \env, done => do
  let src = MkSource efd (do _ <- eventfdRead efd
                             modifyIORef drains S
                             when fires (done "woken by the source"))
  Right cancel <- env.addSource src
    | Left e => done ("addSource " ++ show e) *> pure noCancel
  when fires (ignore (eventfdWrite efd 1))
  pure cancel

sourceTest : IO ()
sourceTest = do
  Right efd <- eventfd 0 (EFD_NONBLOCK .|. EFD_CLOEXEC)
    | Left e => putStrLn ("eventfd: " ++ show e)
  drains <- newIORef 0
  r <- runTask (sourceOp efd drains True)
  putStrLn ("source: " ++ show r)
  n <- readIORef drains
  putStrLn ("drains: " ++ show n)

  -- a given-up operation takes its source out: writing to the descriptor
  -- afterwards drains nothing
  (r2, _) <- runTaskVirtual (do
    won <- race (sourceOp efd drains False) (sleepFor 10)
    liftIO (ignore (eventfdWrite efd 1))
    sleepFor 10
    pure won)
  putStrLn ("race: " ++ show r2)
  n2 <- readIORef drains
  putStrLn ("drains after the cancel: " ++ show n2)
  ignore (close efd)

main : IO ()
main = slotTest *> sourceTest
