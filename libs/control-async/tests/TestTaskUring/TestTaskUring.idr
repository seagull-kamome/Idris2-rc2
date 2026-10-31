module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Control.Task.Uring: io_uring requests as Tasks on the ring that the first
-- request makes. A nop, a file written and read back, two requests at once,
-- a read that waits for a write of another task, and a request given up by a
-- race (the clock is virtual: no real time passes, the order is exact).

import Control.Task
import Control.Task.Scheduler
import Control.Task.Uring
import Data.Bits
import Data.Buffer
import System.File
import System.Linux.Pipe
import System.Linux.Uring
import System.Posix.Errno
import System.Posix.File
import System.Posix.FileDesc

%default covering

path : String
path = "task_uring_test_file.tmp"

showCount : Either Errno Nat -> String
showCount = either show show

fileRoundTrip : Buffer -> Buffer -> Task (Either Errno String)
fileRoundTrip out back = do
  Right w <- uringOpenat Nothing path (O_CREAT .|. O_WRONLY .|. O_TRUNC) 0o644
    | Left e => pure (Left e)
  Right n <- uringWrite w out 5 0
    | Left e => pure (Left e)
  Right () <- uringFsync w 0
    | Left e => pure (Left e)
  Right () <- uringClose w
    | Left e => pure (Left e)
  Right r <- uringOpenat Nothing path O_RDONLY 0
    | Left e => pure (Left e)
  Right m <- uringRead r back 5 0
    | Left e => pure (Left e)
  Right () <- uringClose r
    | Left e => pure (Left e)
  s <- liftIO (getString back 0 5)
  pure (Right (show n ++ " bytes written, " ++ show m ++ " read: " ++ s))

main : IO ()
main = do
  Just out <- newBuffer 5
    | Nothing => putStrLn "newBuffer failed"
  setString out 0 "hello"
  Just back <- newBuffer 5
    | Nothing => putStrLn "newBuffer failed"
  Right (rfd, wfd) <- pipe2 0
    | Left e => putStrLn ("pipe2: " ++ show e)

  r1 <- runTask uringNop
  putStrLn ("nop: " ++ show r1)

  r2 <- runTask (fileRoundTrip out back)
  _ <- removeFile path
  putStrLn ("file: " ++ show r2)

  r3 <- runTask (both uringNop uringNop)
  putStrLn ("both: " ++ show r3)

  -- the read starts first and waits; the write of the other task completes it
  Just got <- newBuffer 5
    | Nothing => putStrLn "newBuffer failed"
  r4 <- runTask (both (uringRead rfd got 5 0) (uringWrite wfd out 5 0))
  line <- getString got 0 5
  putStrLn ("pipe: " ++ show (map showCount (fst <$> r4), map showCount (snd <$> r4)) ++ " " ++ show line)

  -- a read that nothing answers is given up when the other side wins
  (r5, _) <- runTaskVirtual (race (uringRead rfd got 5 0) (sleepFor 10))
  putStrLn ("race: " ++ show (map (either (const "read") (const "timer")) r5))

  -- failures are errnos
  r6 <- runTask (uringClose wfd *> uringClose wfd)
  putStrLn ("closed twice: " ++ show r6)
