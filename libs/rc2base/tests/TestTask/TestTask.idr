module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Control.Task: the monad, both/race/spawn, cancellation, timers, the epoll
-- source on a pipe, an Async written by hand, and a completion that comes
-- from another thread through the inbox. Whatever waits only for timers runs
-- on the virtual clock (`runTaskVirtual`): no real time passes, the order and
-- the time of the events are exact. What needs real threads (workers, a
-- completion from another thread) is made to meet by flags the jobs wait for
-- and not by how long they take.

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
  Right n <- read fd buf
    | Left e => pure (Left e)
  bs <- traverse (getBits8 buf) (map cast (the (List Nat) (if n == 0 then [] else [0 .. n `minus` 1])))
  pure (Right (pack (map (chr . cast) bs)))

-- sleep in real time
nap : Nat -> IO ()
nap ms = ignore (nanosleep (MkTimeSpec (cast (ms `div` 1000)) (cast ((ms `mod` 1000) * 1000000))))

-- wait for a flag that another thread sets, at most `ms` milliseconds
waitFlag : IORef Bool -> Nat -> IO Bool
waitFlag flag Z = readIORef flag
waitFlag flag (S k) = do
  set <- readIORef flag
  if set then pure True else nap 1 *> waitFlag flag k

-- Two parties each say they are here and wait (a while) for the other: both
-- get `True` only if they run at the same time.
meet : (mine : IORef Bool) -> (theirs : IORef Bool) -> IO Bool
meet mine theirs = writeIORef mine True *> waitFlag theirs 400

sleepers : IORef (List String) -> Task ()
sleepers l = do
  spawn (sleepFor 60 *> logTo l "60")
  spawn (sleepFor 20 *> logTo l "20")
  spawn (sleepFor 40 *> logTo l "40")
  logTo l "start"

-- a job that records that it ran (from a worker thread, once)
liftIO' : IORef (List String) -> IO ()
liftIO' ref = modifyIORef ref ("ran" ::)

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
  (_, t1) <- runTaskVirtual (sleepers l1)
  report "three sleepers" l1
  putStrLn ("ended at " ++ show t1)

  -- both
  l2 <- newIORef []
  (r5, t5) <- runTaskVirtual (both (sleepFor 40 *> logTo l2 "left" *> pure (the Nat 1)) (sleepFor 10 *> logTo l2 "right" *> pure "r"))
  putStrLn ("both: " ++ show r5 ++ ", ended at " ++ show t5)
  report "both order" l2

  -- race: the loser is cancelled and the end does not wait for it
  (r6, t6) <- runTaskVirtual (race (sleepFor 800 *> pure "slow") (sleepFor 10 *> pure "fast"))
  putStrLn ("race: " ++ show r6 ++ ", ended at " ++ show t6 ++ " (the loser is not waited for)")
  l3 <- newIORef []
  (r7, t7) <- runTaskVirtual (race (do spawn (sleepFor 600 *> logTo l3 "leak"); sleepFor 10; logTo l3 "left wins")
                                    (sleepFor 800))
  putStrLn ("race with a spawn: " ++ show r7 ++ ", ended at " ++ show t7)
  report "race with a spawn" l3
  (r8, t8) <- runTaskVirtual (Race (sleepFor 30 *> pure (the Nat 1)) Empty)
  putStrLn ("race with Empty: " ++ show r8 ++ ", ended at " ++ show t8)
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
  (r10, t10) <- runTaskVirtual (race (the (Task ()) (Async (\env, done => pure (MkCancel (modifyIORef cancels (+ 1))))))
                                     (sleepFor 10 *> pure "timer"))
  readIORef cancels >>= \n => putStrLn ("hand-made Async: " ++ show r10 ++ ", cancelled " ++ show n ++ " time(s), ended at " ++ show t10)

  -- a completion from another thread
  -- (the thread is joined before the scheduler is closed: its write to the inbox
  -- must be ordered before the close of the descriptor)
  thread <- newIORef Nothing
  r11 <- runTask (do
    x <- Async (\env, done => do
           h <- forkJoin (env.post (done (the Nat 42)))
           writeIORef thread (Just h)
           pure noCancel)
    onReactor (readIORef thread >>= maybe (pure ()) join)
    pure x)
  putStrLn ("from another thread: " ++ show r11)


  -- promises
  l6 <- newIORef []
  (r15, _) <- runTaskVirtual (do
    p <- fork (sleepFor 30 *> logTo l6 "producer" *> pure (the Nat 7))
    logTo l6 "forked"
    a <- wait p
    b <- wait p
    pure (a + b))
  putStrLn ("fork/wait twice: " ++ show r15)
  report "fork order" l6
  r16 <- runTask (do
    p <- fork (pure (the Nat 5))
    yield
    yield
    mine <- peek p
    late <- wait p
    pure (mine, late))
  putStrLn ("peek after the result is in: " ++ show r16)
  l7 <- newIORef []
  _ <- runTaskVirtual (do
    p <- fork (sleepFor 40 *> pure (the Nat 1))
    spawn (do x <- wait p; logTo l7 ("A " ++ show x))
    spawn (do x <- wait p; logTo l7 ("B " ++ show x))
    logTo l7 "waiting")
  report "two waiters" l7
  -- a waiter that is given up, and a promise whose producer is given up
  (r17, _) <- runTaskVirtual (do
    loser <- race (do p <- fork (sleepFor 500 *> pure (the Nat 1)); waitMaybe p) (sleepFor 20)
    pure (either (const "waited") (const "timer") loser))
  putStrLn ("a waiter given up: " ++ show r17)
  (r18, t18) <- runTaskVirtual (do
    holder <- Point (newIORef Nothing)
    -- the producer is started inside a race that the timer wins
    _ <- race (do p <- fork (sleepFor 800 *> pure (the Nat 2))
                  Point (writeIORef holder (Just p))
                  wait p)
              (sleepFor 10)
    Just p <- Point (readIORef holder)
      | Nothing => pure "no promise"
    r <- waitMaybe p
    pure (show r))
  putStrLn ("abandoned promise: " ++ show r18 ++ ", ended at " ++ show t18)


  -- blocking: the action runs on a worker
  r19 <- runTask (blocking (pure (the Nat 9)))
  putStrLn ("blocking without workers: " ++ show r19)
  -- the reactor goes on while a worker is busy: the job waits for a tick the
  -- reactor makes (a timer on the real clock) and gives up after 5 s
  ticked <- newIORef False
  l8 <- newIORef []
  r20 <- runTaskWith 1 (do
    spawn (sleepFor 20 *> onReactor (writeIORef ticked True) *> logTo l8 "tick")
    saw <- blocking (waitFlag ticked 5000)
    logTo l8 ("the job saw the tick: " ++ show saw)
    pure saw)
  putStrLn ("the reactor goes on: " ++ show r20)
  report "events" l8
  -- two workers run two jobs at the same time ...
  a2 <- newIORef False
  b2 <- newIORef False
  r21 <- runTaskWith 2 (both (blocking (meet a2 b2)) (blocking (meet b2 a2)))
  putStrLn ("two workers meet: " ++ show r21)
  -- ... one worker cannot: the first job gives up waiting before the second starts
  a1 <- newIORef False
  b1 <- newIORef False
  r21b <- runTaskWith 1 (both (blocking (meet a1 b1)) (blocking (meet b1 a1)))
  putStrLn ("one worker does not: " ++ show r21b)
  -- a job queued behind a busy worker, whose task is given up, never runs: the
  -- worker is held until the race is over
  release <- newIORef False
  l9 <- newIORef []
  r22 <- runTaskWith 1 (do
    spawn (map (const ()) (blocking (waitFlag release 5000)))
    yield
    r <- race (blocking (liftIO' l9)) (sleepFor 20)
    onReactor (writeIORef release True)
    pure r)
  putStrLn ("a queued job given up: " ++ show (map (either (const "ran") (const "dropped")) r22))
  l10 <- readIORef l9
  putStrLn ("it never ran: " ++ show (null l10))
  r23 <- runTaskWith 4 (do
    ps <- traverse (\i => fork (blocking (pure (i * 2)))) (the (List Nat) [1 .. 200])
    xs <- traverse wait ps
    pure (sum xs))
  putStrLn ("200 jobs on 4 workers: " ++ show r23)


  -- runTaskFirst: the end of the first task gives up what is left
  l11 <- newIORef []
  r24 <- runTaskFirst 0 (do
    spawn (sleepFor 800 *> logTo l11 "late")
    sleepFor 20
    pure (the Nat 3))
  putStrLn ("runTaskFirst: " ++ show r24)
  readIORef l11 >>= \xs => putStrLn ("what was left did not run: " ++ show (null xs))

  -- parallel mode: the Points of different tasks run at the same time
  a3 <- newIORef False
  b3 <- newIORef False
  r25 <- runTaskWith 2 (both (liftIO (meet a3 b3)) (liftIO (meet b3 a3)))
  putStrLn ("cooperative Points do not meet: " ++ show r25)
  a4 <- newIORef False
  b4 <- newIORef False
  r26 <- runTaskParallel 2 (both (liftIO (meet a4 b4)) (liftIO (meet b4 a4)))
  putStrLn ("parallel Points meet: " ++ show r26)
  l12 <- newIORef []
  r27 <- runTaskParallel 3 (do
    ps <- traverse (\i => fork (liftIO (pure (i * i)))) (the (List Nat) [1 .. 50])
    xs <- traverse wait ps
    onReactor (modifyIORef l12 ("summed" ::))
    pure (sum xs))
  putStrLn ("promises in parallel mode: " ++ show r27)
  readIORef l12 >>= \xs => putStrLn ("onReactor ran: " ++ show xs)
  r28 <- runTaskParallel 0 (map (+ 1) (liftIO (pure (the Nat 4))))
  putStrLn ("parallel mode without workers: " ++ show r28)

  -- the epoll source on a pipe
  Right (rd, wr) <- pipe2 (O_NONBLOCK .|. O_CLOEXEC)
    | Left e => putStrLn ("pipe2: " ++ show e)
  l5 <- newIORef []
  _ <- runTaskVirtual (do
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
  (r12, t12) <- runTaskVirtual (race (awaitReadable rd2) (sleepFor 10))
  putStrLn ("a cancelled fd wait: " ++ show (map (either (const "readable") (const "timer")) r12) ++ ", ended at " ++ show t12)

  -- hang-up wakes a reader
  Right (rd3, wr3) <- pipe2 (O_NONBLOCK .|. O_CLOEXEC)
    | Left e => putStrLn ("pipe2: " ++ show e)
  (r13, _) <- runTaskVirtual (do
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
