module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- System.Posix.Async.Process: a program that reads its input and writes its
-- output, an exit code, a kill by signal, a wait given up, two tasks waiting
-- for one child, an output larger than a pipe, and a program that is not there.

import Control.Task
import Control.Task.Scheduler
import Data.Buffer
import Data.List
import Data.Maybe
import Data.String
import System
import System.Posix.Async.File as A
import System.Posix.Async.Process
import System.Posix.Errno
import System.Posix.Process
import System.Posix.Signal

%default covering

-- sh finds the programs it runs in the PATH of this process.
shell : String -> IO (String, List String, List String)
shell script = do
  path <- getEnv "PATH"
  pure ("/bin/sh", ["sh", "-c", script], ["PATH=" ++ fromMaybe "/bin:/usr/bin" path])

signalName : Int32 -> String
signalName n =
  if n == cast SIGTERM then "killed by TERM"
  else if n == cast SIGKILL then "killed by KILL"
  else "killed"

how : Either Errno ProcessStatus -> String
how (Left _) = "error"
how (Right st) = case (exitedWith st, killedBy st) of
  (Just code, _) => "exit " ++ show code
  (_, Just sig) => signalName (the Int32 (cast sig))
  _ => "other"

run : String -> Task (Either Errno Child)
run script = do
  (path, argv, envp) <- liftIO (shell script)
  spawn path "/" argv envp

captureTest : Task String
captureTest = do
  (path, argv, envp) <- liftIO (shell "cat; echo done")
  r <- captureOutput path "/" argv envp "hello\n"
  pure $ case r of
    Left _ => "error"
    Right (st, out) => how (Right st) ++ ", " ++ show out

exitTest : Task String
exitTest = do
  Right c <- run "exit 7"
    | Left _ => pure "spawn failed"
  withChild c (map how (waitChild c))

terminateTest : Task String
terminateTest = do
  Right c <- run "exec sleep 30"
    | Left _ => pure "spawn failed"
  withChild c (map how (terminate c 2000))

givenUpTest : Task String
givenUpTest = do
  Right c <- run "exec sleep 30"
    | Left _ => pure "spawn failed"
  withChild c $ do
    lost <- race (waitChild c) (sleepFor 20)
    st <- terminate c 2000
    pure (either (const "wait won") (const "timer won") lost ++ ", then " ++ how st)

-- Both waiters are waiting when the child ends; a third asks after the reaping.
twoWaitersTest : Task String
twoWaitersTest = do
  Right c <- run "read x; exit 3"
    | Left _ => pure "spawn failed"
  withChild c $ do
    a <- fork (waitChild c)
    b <- fork (waitChild c)
    sleepFor 20
    A.close c.stdin
    x <- wait a
    y <- wait b
    z <- waitChild c
    pure (how x ++ ", " ++ how y ++ ", " ++ how z)

bigTest : Task String
bigTest = do
  (path, argv, envp) <- liftIO (shell "yes | head -c 300000")
  r <- captureOutput path "/" argv envp ""
  pure $ case r of
    Left _ => "error"
    Right (st, out) => how (Right st) ++ ", " ++ show (length out) ++ " bytes"

-- A child that ignores SIGTERM is killed after the grace; a signal to a child
-- that has been reaped is ESRCH.
stubbornTest : Task String
stubbornTest = do
  Right c <- run "trap '' TERM; echo ready; read x"
    | Left _ => pure "spawn failed"
  withChild c $ do
    Just buf <- liftIO (newBuffer 16)
      | Nothing => pure "no buffer"
    _ <- A.read c.stdout buf 0 16
    st <- terminate c 50
    late <- signalChild c SIGTERM
    pure (how st ++ ", then " ++ either (\e => if e == ESRCH then "ESRCH" else "other") (const "sent") late)

missingTest : Task String
missingTest = do
  r <- spawn "/nonexistent/TestPosixAsyncProcess" "/" ["x"] []
  pure $ case r of
    Left e => if e == ENOENT then "ENOENT" else "other"
    Right _ => "started"

main : IO ()
main = do
  r <- runTask (do
         a <- captureTest
         b <- exitTest
         c <- terminateTest
         d <- givenUpTest
         e <- twoWaitersTest
         f <- bigTest
         g <- missingTest
         h <- stubbornTest
         pure [ "capture: " ++ a, "exit: " ++ b, "terminate: " ++ c, "given up: " ++ d
              , "two waiters: " ++ e, "big: " ++ f, "missing: " ++ g, "stubborn: " ++ h ])
  traverse_ putStrLn (maybe ["no result"] id r)
