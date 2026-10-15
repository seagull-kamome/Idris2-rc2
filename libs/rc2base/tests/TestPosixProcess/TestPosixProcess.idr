module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- System.Posix.Process: getpid, kill (signal 0 to itself, SIGKILL to a
-- child it forked), fork + exit + wait/waitpid, and the wait option
-- constants (compared with a plain C program through the .expected file).
-- Only the test's own children are ever signalled.

import Data.Bits
import Data.Maybe
import System
import System.File
import System.FFI
import System.Posix.Errno
import System.Posix.Fcntl
import System.Posix.File
import System.Posix.FileDesc
import System.Posix.Poll
import System.Posix.Process
import System.Posix.Signal
import System.Posix.Time

opt : String -> Int32 -> IO ()
opt n v = putStrLn (n ++ "=" ++ show v)

exitCode : ProcessStatus -> Int32
exitCode (MkProcessStatus s) = (s `shiftR` 8) .&. 255

testTime : IO ()
testTime = do
  putStrLn "-- time"
  Right t1 <- clock_gettime CLOCK_MONOTONIC
    | Left _ => putStrLn "clock_gettime failed"
  Right rt <- clock_gettime CLOCK_REALTIME
    | Left _ => putStrLn "clock_gettime realtime failed"
  now <- time
  putStrLn ("realtime close to time(): " ++ show (abs (rt.tvSec - now) <= 2))
  putStrLn ("nsec in range: " ++ show (t1.tvNsec >= 0 && t1.tvNsec < 1000000000))
  Right res <- clock_getres CLOCK_MONOTONIC
    | Left _ => putStrLn "clock_getres failed"
  putStrLn ("resolution is positive: " ++ show (res.tvSec > 0 || res.tvNsec > 0))
  Right () <- nanosleep (MkTimeSpec 0 20000000)
    | Left _ => putStrLn "nanosleep failed"
  Right t2 <- clock_gettime CLOCK_MONOTONIC
    | Left _ => putStrLn "clock_gettime failed"
  putStrLn ("monotonic advanced by >= 20ms: " ++ show (t2.tvSec * 1000000000 + t2.tvNsec - t1.tvSec * 1000000000 - t1.tvNsec >= 20000000))
  -- 2001-09-09 01:46:40 UTC is 1000000000 (a Sunday, day 251 of the year)
  Right tm <- gmtime 1000000000
    | Left _ => putStrLn "gmtime failed"
  printLn tm
  strftime "%Y-%m-%d %H:%M:%S" tm >>= printLn
  strftime "%a %b %e" tm >>= printLn
  Right tm0 <- gmtime 0
    | Left _ => putStrLn "gmtime failed"
  printLn tm0
  Right lt <- localtime 1000000000
    | Left _ => putStrLn "localtime failed"
  putStrLn ("localtime year: " ++ show lt.tmYear)
  -- a round trip through mktime (local time) is the identity
  mktime lt >>= printLn
  mktime (MkTm 0 0 0 1 0 70 0 0 0) >>= \r => putStrLn ("mktime epoch is a Just: " ++ show (isJust r))

errnum : Errno -> Int32
errnum (MkErrno n) = n

errOf : Either Errno a -> String
errOf (Left e) = "errno " ++ show (errnum e)
errOf (Right _) = "ok"

testInfo : IO ()
testInfo = do
  putStrLn "-- ids"
  ppid <- getppid
  putStrLn ("getppid positive: " ++ show (cast {to=Int32} ppid > 0))
  uid <- getuid
  euid <- geteuid
  gid <- getgid
  egid <- getegid
  putStrLn ("uid==euid, gid==egid: " ++ show (uid == euid && gid == egid))
  Right pg <- getpgid (cast (the Int32 0))
    | Left _ => putStrLn "getpgid failed"
  pg2 <- getpgrp
  putStrLn ("getpgid(0) == getpgrp: " ++ show (cast {to=Int32} pg == cast {to=Int32} pg2))
  Right sid <- getsid (cast (the Int32 0))
    | Left _ => putStrLn "getsid failed"
  putStrLn ("getsid positive: " ++ show (cast {to=Int32} sid > 0))
  Left e <- setpgid (cast (the Int32 2147483647)) (cast (the Int32 0))
    | Right _ => putStrLn "setpgid on a missing process: unexpectedly ok"
  putStrLn ("setpgid missing process: errno " ++ show (errnum e))
  nice 0 >>= \n => putStrLn ("nice 0 in range: " ++ show (either (const False) (\v => v >= -20 && v <= 19) n))
  putStrLn "-- limits and system"
  Right rl <- getrlimit RLIMIT_NOFILE
    | Left _ => putStrLn "getrlimit failed"
  putStrLn ("nofile soft <= hard: " ++ show (rl.soft <= rl.hard))
  Right () <- setrlimit RLIMIT_NOFILE rl
    | Left _ => putStrLn "setrlimit failed"
  putStrLn "setrlimit same value: ok"
  Right un <- uname
    | Left _ => putStrLn "uname failed"
  putStrLn ("uname sysname is not empty: " ++ show (un.sysname /= "" && un.machine /= ""))
  Right hn <- gethostname
    | Left _ => putStrLn "gethostname failed"
  putStrLn ("gethostname is not empty: " ++ show (hn /= ""))
  sysconf SC_PAGESIZE >>= \r => putStrLn ("page size is a power of two: " ++ show (maybe False (\n => n > 0 && (n `mod` 2 == 0)) r))
  sysconf SC_NPROCESSORS_ONLN >>= \r => putStrLn ("cpus >= 1: " ++ show (maybe False (>= 1) r))
  sysconf SC_CLK_TCK >>= \r => putStrLn ("clock ticks > 0: " ++ show (maybe False (> 0) r))

testPipe : IO ()
testPipe = do
  putStrLn "-- pipe, fcntl, poll"
  Right (rd, wr) <- pipe
    | Left _ => putStrLn "pipe failed"
  poll [(rd, POLLIN)] 0 >>= \r => putStrLn ("empty pipe, POLLIN: " ++ show r)
  poll [(wr, POLLOUT)] 0 >>= \r => putStrLn ("pipe write end, POLLOUT: " ++ show (map (map (== POLLOUT)) r))
  _ <- write wr "ping"
  poll [(rd, POLLIN), (wr, POLLOUT)] 1000 >>= \r => putStrLn ("after write: " ++ show (map (map (\e => e /= 0)) r))
  getFdFlags rd >>= \r => putStrLn ("cloexec off by default: " ++ show r)
  Right () <- setFdFlags rd FD_CLOEXEC
    | Left _ => putStrLn "setFdFlags failed"
  getFdFlags rd >>= \r => putStrLn ("cloexec on: " ++ show r)
  Right fl <- getStatusFlags rd
    | Left _ => putStrLn "getStatusFlags failed"
  Right () <- setStatusFlags rd (fl .|. O_NONBLOCK)
    | Left _ => putStrLn "setStatusFlags failed"
  Right fl2 <- getStatusFlags rd
    | Left _ => putStrLn "getStatusFlags failed"
  putStrLn ("nonblock set: " ++ show ((fl2 .&. O_NONBLOCK) /= 0))
  Right d <- dupfdCloexec rd 10
    | Left _ => putStrLn "dupfd failed"
  putStrLn ("dupfd at least 10: " ++ show (d.rawfd >= 10))
  _ <- close d
  _ <- close wr
  poll [(rd, POLLIN)] 1000 >>= \r => putStrLn ("hangup with data pending: " ++ show (map (map (\e => (e .&. POLLIN) /= 0)) r))
  _ <- close rd
  poll [(rd, POLLIN)] 0 >>= \r => putStrLn ("closed descriptor: " ++ show (map (map (== POLLNVAL)) r))

testExec : IO ()
testExec = do
  putStrLn "-- exec"
  e <- execv "/no/such/program" ["x"]
  putStrLn ("execv missing: errno " ++ show (errnum e))
  ignore $ fflush stdout
  c <- fork
  if cast {to=Int32} c == 0
    then do _ <- execvp "sh" ["sh", "-c", "exit 3"]
            exitNow 127
    else pure ()
  Right (_, st) <- waitpid c 0
    | Left _ => putStrLn "waitpid failed"
  putStrLn ("exec sh -c 'exit 3': exited " ++ show (exitedWith st) ++ ", signal " ++ show (map (\(MkSignal x) => x) (killedBy st)))
  ignore $ fflush stdout
  c2 <- fork
  if cast {to=Int32} c2 == 0
    then do _ <- execve "/bin/sh" ["sh", "-c", "test \"$FOO\" = bar"] ["FOO=bar"]
            exitNow 127
    else pure ()
  Right (_, st2) <- waitpid c2 0
    | Left _ => putStrLn "waitpid failed"
  putStrLn ("execve with env: exited " ++ show (exitedWith st2))

main : IO ()
main = do
  opt "WEXITED" WEXITED
  opt "WSTOPPED" WSTOPPED
  opt "WNOHANG" WNOHANG
  opt "WUNTRACED" WUNTRACED
  opt "WCONTINUED" WCONTINUED
  me <- getpid
  testTime
  testInfo
  testPipe
  testExec
  putStrLn ("getpid positive: " ++ show (cast {to=Int32} me > 0))
  kill me (cast {to=Signal} (the Int32 0)) >>= \r => putStrLn ("kill self 0: " ++ errOf r)
  -- child 1: exits with status 7
  ignore $ fflush stdout
  c1 <- fork
  if (cast {to=Int32} c1) == 0
    then exit 7
    else pure ()
  Right (p1, st1) <- waitpid c1 0
    | Left _ => putStrLn "waitpid failed"
  putStrLn ("child 1 pid matches: " ++ show (cast {to=Int32} p1 == cast c1))
  putStrLn ("child 1 exit status: " ++ show (exitCode st1))
  -- child 2: killed by SIGKILL while sleeping
  ignore $ fflush stdout
  c2 <- fork
  if (cast {to=Int32} c2) == 0
    then sleep 30 >> exit 0
    else pure ()
  kill c2 SIGKILL >>= \r => putStrLn ("kill child: " ++ errOf r)
  Right (p2, MkProcessStatus st2) <- wait
    | Left _ => putStrLn "wait failed"
  putStrLn ("child 2 pid matches: " ++ show (cast {to=Int32} p2 == cast c2))
  putStrLn ("child 2 terminating signal: " ++ show (st2 .&. 127))
  -- no children left: wait fails with ECHILD, WNOHANG on any child too
  wait >>= \r => putStrLn ("wait without children: " ++ either (\e => "errno " ++ show (errnum e)) (const "ok") r)
  waitpid (cast {to=ProcessID} (the Int32 (-1))) WNOHANG >>= \r => putStrLn ("waitpid WNOHANG without children: " ++ either (\e => "errno " ++ show (errnum e)) (const "ok") r)
  kill (cast {to=ProcessID} (the Int32 2147483647)) (cast {to=Signal} (the Int32 0)) >>= \r => putStrLn ("kill missing process: " ++ either (\e => "errno " ++ show (errnum e)) (const "ok") r)
  -- a child that has not exited: WNOHANG gives process ID 0
  ignore $ fflush stdout
  c3 <- fork
  if cast {to=Int32} c3 == 0
    then sleep 30 >> exitNow 0
    else pure ()
  Right (z, _) <- waitpid c3 WNOHANG
    | Left _ => putStrLn "waitpid failed"
  putStrLn ("WNOHANG on a running child: pid " ++ show (cast {to=Int32} z))
  _ <- kill c3 SIGKILL
  _ <- waitpid c3 0
  pure ()
