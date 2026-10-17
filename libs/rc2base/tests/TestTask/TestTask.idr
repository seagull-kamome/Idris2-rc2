module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Control.Task: the monad, both/race/spawn, cancellation, timers, the epoll
-- source on a pipe, an Async written by hand, and a completion that comes
-- from another thread through the inbox. Times are tens of milliseconds
-- apart; the order of events is what is checked.

import Control.Task
import Control.Task.Scheduler
import Data.Bits
import Data.Buffer
import Data.IORef
import Data.List
import System.Concurrency.RC2
import System.Linux.Epoll
import System.Linux.Pipe
import System.Posix.Errno
import System.Posix.Fcntl
import System.Posix.File
import System.Posix.FileDesc
import System.Posix.Time

%default covering

logTo : IORef (List String) -> String -> Task ()
logTo ref s = liftIO (modifyIORef ref (s ::))

report : String -> IORef (List String) -> IO ()
report title ref = do
  xs <- readIORef ref
  putStrLn (title ++ ": " ++ show (reverse xs))

writeStr : FileDesc -> String -> IO ()
writeStr fd s = do
  let cs = unpack s
      n = length cs
  Just buf <- newBuffer (cast n)
    | Nothing => putStrLn "newBuffer failed"
  traverse_ (\(i, c) => setBits8 buf (cast i) (cast (ord c))) (zip (the (List Nat) [0 .. n `minus` 1]) cs)
  _ <- write fd buf
  pure ()

-- Read what is there; empty at the end of the file or when there is nothing.
readStr : FileDesc -> IO (Either Errno String)
readStr fd = do
  Just buf <- newBuffer 64
    | Nothing => pure (Right "")
  n <- read fd buf
  if n < 0
     then Left <$> errno
     else do bs <- traverse (getBits8 buf) (map cast (the (List Nat) (if n == 0 then [] else [0 .. cast n `minus` 1])))
             pure (Right (pack (map (chr . cast) bs)))

elapsedMs : IO Nat -> IO a -> IO (a, Nat)
elapsedMs clock act = do
  t0 <- clock
  r <- act
  t1 <- clock
  pure (r, t1 `minus` t0)

monoMs : IO Nat
monoMs = do
  Right t <- clock_gettime CLOCK_MONOTONIC
    | Left _ => pure 0
  pure (cast (t.tvSec * 1000 + t.tvNsec `div` 1000000))

sleepers : IORef (List String) -> Task ()
sleepers l = do
  spawn (sleepFor 60 *> logTo l "60")
  spawn (sleepFor 20 *> logTo l "20")
  spawn (sleepFor 40 *> logTo l "40")
  logTo l "start"

countTo : Nat -> Nat -> Task Nat
countTo Z acc = pure acc
countTo (S k) acc = do
  _ <- liftIO (pure ())
  countTo k (acc + 1)

main : IO ()
main = do
  putStrLn "--- Control.Task ---"

  -- the monad
  r1 <- runTask (do x <- pure 20; y <- pure 22; pure (x + y))
  putStrLn ("pure/bind: " ++ show r1)
  r2 <- runTask (countTo 200000 0)
  putStrLn ("a loop of 200000 steps: " ++ show r2)
  r3 <- runTask {a = Nat} Empty
  putStrLn ("Empty: " ++ show r3)
  r4 <- runTask (map (+ 1) (liftIO (pure 1)))
  putStrLn ("map: " ++ show r4)

  -- timers
  l1 <- newIORef []
  _ <- runTask (sleepers l1)
  report "three sleepers" l1

  -- both
  l2 <- newIORef []
  r5 <- runTask (both (sleepFor 40 *> logTo l2 "left" *> pure (the Nat 1)) (sleepFor 10 *> logTo l2 "right" *> pure "r"))
  putStrLn ("both: " ++ show r5)
  report "both order" l2

  -- race: the loser is cancelled and the end does not wait for it
  (r6, ms6) <- elapsedMs monoMs (runTask (race (sleepFor 800 *> pure "slow") (sleepFor 10 *> pure "fast")))
  putStrLn ("race: " ++ show r6 ++ ", no wait for the loser: " ++ show (ms6 < 500))
  l3 <- newIORef []
  (r7, ms7) <- elapsedMs monoMs (runTask (race (do spawn (sleepFor 600 *> logTo l3 "leak"); sleepFor 10; logTo l3 "left wins")
                                               (sleepFor 800)))
  putStrLn ("race with a spawn: " ++ show r7 ++ ", quick: " ++ show (ms7 < 500))
  report "race with a spawn" l3
  r8 <- runTask (Race (sleepFor 30 *> pure (the Nat 1)) Empty)
  putStrLn ("race with Empty: " ++ show r8)
  r9 <- runTask (the (Task Nat) (Empty <|> pure 7))
  putStrLn ("<|>: " ++ show r9)

  -- fairness: yield lets the others run
  l4 <- newIORef []
  _ <- runTask (do
    _ <- both (traverse_ (\i => logTo l4 ("a" ++ show i) *> yield) [1, 2, 3])
              (traverse_ (\i => logTo l4 ("b" ++ show i) *> yield) [1, 2, 3])
    pure ())
  report "yield" l4

  -- a hand-made Async, cancelled by a race
  cancels <- newIORef (the Nat 0)
  (r10, ms10) <- elapsedMs monoMs (runTask (race (the (Task ()) (Async (\env, done => pure (MkCancel (modifyIORef cancels (+ 1))))))
                                                (sleepFor 10 *> pure "timer")))
  readIORef cancels >>= \n => putStrLn ("hand-made Async: " ++ show r10 ++ ", cancelled " ++ show n ++ " time(s), quick: " ++ show (ms10 < 500))

  -- a completion from another thread
  r11 <- runTask (Async (\env, done => do
                   _ <- forkJoin (env.post (done (the Nat 42)))
                   pure noCancel))
  putStrLn ("from another thread: " ++ show r11)

  -- the epoll source on a pipe
  Right (rd, wr) <- pipe2 (O_NONBLOCK .|. O_CLOEXEC)
    | Left e => putStrLn ("pipe2: " ++ show e)
  l5 <- newIORef []
  _ <- runTask (do
    spawn (do ev <- awaitReadable rd
              s <- liftIO (readStr rd)
              logTo l5 ("reader A: " ++ show (hasEvent EPOLLIN ev) ++ " " ++ show s))
    spawn (do ev <- awaitReadable rd
              logTo l5 ("reader B woke: " ++ show (hasEvent EPOLLIN ev)))
    spawn (do ev <- awaitWritable wr
              logTo l5 ("writable: " ++ show (hasEvent EPOLLOUT ev)))
    sleepFor 30
    logTo l5 "writing"
    liftIO (writeStr wr "hi"))
  report "pipe" l5

  -- a wait that is given up leaves nothing behind: the run ends
  Right (rd2, wr2) <- pipe2 (O_NONBLOCK .|. O_CLOEXEC)
    | Left e => putStrLn ("pipe2: " ++ show e)
  (r12, ms12) <- elapsedMs monoMs (runTask (race (awaitReadable rd2) (sleepFor 10)))
  putStrLn ("a cancelled fd wait: " ++ show (map (either (const "readable") (const "timer")) r12) ++ ", quick: " ++ show (ms12 < 500))

  -- hang-up wakes a reader
  Right (rd3, wr3) <- pipe2 (O_NONBLOCK .|. O_CLOEXEC)
    | Left e => putStrLn ("pipe2: " ++ show e)
  r13 <- runTask (do
    spawn (sleepFor 20 *> liftIO (ignore (close wr3)))
    ev <- awaitReadable rd3
    pure (hasEvent EPOLLHUP ev))
  putStrLn ("hang-up: " ++ show r13)

  -- a regular file cannot be watched by epoll: it is always ready
  Right file <- openFile "/dev/null" 0 0
    | Left e => putStrLn ("open: " ++ show e)
  r14 <- runTask (map (hasEvent EPOLLIN) (awaitReadable file))
  putStrLn ("a file is ready: " ++ show r14)
  traverse_ (\fd => ignore (close fd)) [rd, wr, rd2, wr2, rd3, file]
