module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- System.Linux.*: pipe2 with O_CLOEXEC / O_NONBLOCK set at creation.
-- pipe2 is declared by glibc only under _GNU_SOURCE, so verify.sh builds
-- this test with IDRIS2_CFLAGS=-D_GNU_SOURCE.

import Data.Bits
import Data.Buffer
import Data.List
import Data.String
import System
import System.FFI
import System.Posix.Errno
import System.Posix.Fcntl
import System.Posix.File
import System.Posix.FileDesc
import System.Linux.Clock
import System.Linux.Copy
import System.Linux.Epoll
import System.Linux.Eventfd
import System.Linux.Dl
import System.Linux.Inotify
import System.Linux.Memfd
import System.Linux.Pipe
import System.Linux.Prctl
import System.Linux.Process
import System.Linux.Random
import System.Linux.Statx
import System.Linux.Signalfd
import System.Linux.Timerfd
import System.Directory
import System.Posix.Dl
import System.Posix.Path
import System.Posix.Poll
import System.Posix.Process
import System.Posix.Signal
import System.Posix.Stat
import System.Posix.Time

errnum : Errno -> Int32
errnum (MkErrno n) = n

errOf : Either Errno a -> String
errOf (Left e) = "errno " ++ show (errnum e)
errOf (Right _) = "ok"

testClock : IO ()
testClock = do
  putStrLn "-- clock"
  Right a <- clock_gettime CLOCK_MONOTONIC_RAW
    | Left _ => putStrLn "clock_gettime failed"
  Right b <- clock_gettime CLOCK_BOOTTIME
    | Left _ => putStrLn "clock_gettime failed"
  Right c <- clock_gettime CLOCK_REALTIME_COARSE
    | Left _ => putStrLn "clock_gettime failed"
  putStrLn ("raw, boottime and coarse clocks read: " ++ show (a.tvSec >= 0 && b.tvSec >= 0 && c.tvSec > 0))

testTimerfd : IO ()
testTimerfd = do
  putStrLn "-- timerfd"
  Right tfd <- timerfd_create CLOCK_MONOTONIC TFD_NONBLOCK
    | Left _ => putStrLn "timerfd_create failed"
  timerfd_read tfd >>= \r => putStrLn ("nothing expired yet: " ++ errOf r)
  Right old <- timerfd_settime tfd 0 (MkITimerSpec (MkTimeSpec 0 0) (MkTimeSpec 0 30000000))
    | Left _ => putStrLn "timerfd_settime failed"
  putStrLn ("previous setting was disarmed: " ++ show (old == MkITimerSpec (MkTimeSpec 0 0) (MkTimeSpec 0 0)))
  Right cur <- timerfd_gettime tfd
    | Left _ => putStrLn "timerfd_gettime failed"
  putStrLn ("armed, not yet due: " ++ show (cur.value.tvNsec > 0 || cur.value.tvSec > 0))
  poll [(tfd, POLLIN)] 2000 >>= \r => putStrLn ("poll sees the expiry: " ++ show (map (map (\e => e /= 0)) r))
  timerfd_read tfd >>= \r => putStrLn ("one expiration: " ++ show r)
  -- periodic: sleep long enough for several ticks, then read the count
  Right _ <- timerfd_settime tfd 0 (MkITimerSpec (MkTimeSpec 0 10000000) (MkTimeSpec 0 10000000))
    | Left _ => putStrLn "timerfd_settime failed"
  _ <- nanosleep (MkTimeSpec 0 100000000)
  Right n <- timerfd_read tfd
    | Left _ => putStrLn "timerfd_read failed"
  putStrLn ("periodic timer ticked at least 5 times: " ++ show (n >= 5))
  _ <- timerfd_settime tfd 0 (MkITimerSpec (MkTimeSpec 0 0) (MkTimeSpec 0 0))
  timerfd_read tfd >>= \r => putStrLn ("disarmed: " ++ errOf r)
  _ <- close tfd
  pure ()

testSignalfd : IO ()
testSignalfd = do
  putStrLn "-- signals"
  Right set <- sigSetOf [SIGUSR1, SIGUSR2]
    | Left _ => putStrLn "sigSetOf failed"
  sigismember set SIGUSR1 >>= \b => putStrLn ("USR1 in set: " ++ show b)
  sigismember set SIGINT >>= \b => putStrLn ("INT in set: " ++ show b)
  _ <- sigdelset set SIGUSR2
  sigismember set SIGUSR2 >>= \b => putStrLn ("USR2 after sigdelset: " ++ show b)
  _ <- sigaddset set SIGUSR2
  Right _ <- sigprocmask SIG_BLOCK set
    | Left _ => putStrLn "sigprocmask failed"
  _ <- raise SIGUSR1
  Right pend <- sigpending
    | Left _ => putStrLn "sigpending failed"
  sigismember pend SIGUSR1 >>= \b => putStrLn ("USR1 pending after raise: " ++ show b)
  sigismember pend SIGUSR2 >>= \b => putStrLn ("USR2 pending: " ++ show b)
  sigwait set >>= \r => putStrLn ("sigwait takes it: " ++ show (map (\(MkSignal n) => n == (let MkSignal u = SIGUSR1 in u)) r))
  -- through a signalfd
  Right sfd <- signalfd set SFD_NONBLOCK
    | Left _ => putStrLn "signalfd failed"
  readSignal sfd >>= \r => putStrLn ("nothing pending: " ++ errOf r)
  me <- getpid
  _ <- kill me SIGUSR2
  Right info <- readSignal sfd
    | Left _ => putStrLn "readSignal failed"
  putStrLn ("signalfd read: " ++ show (let MkSignal a = info.signo; MkSignal b = SIGUSR2 in a == b)
            ++ ", sent by this process: " ++ show (cast {to=Int32} info.pid == cast {to=Int32} me))
  _ <- close sfd
  _ <- sigprocmask SIG_UNBLOCK set
  -- alarm: block SIGALRM and take it as a value
  Right aset <- sigSetOf [SIGALRM]
    | Left _ => putStrLn "sigSetOf failed"
  _ <- sigprocmask SIG_BLOCK aset
  before <- alarm 1
  putStrLn ("no alarm was set before: " ++ show (before == 0))
  sigwait aset >>= \r => putStrLn ("SIGALRM taken by sigwait: " ++ show (map (\(MkSignal n) => let MkSignal a = SIGALRM in n == a) r))
  left <- alarm 0
  putStrLn ("nothing left to cancel: " ++ show (left == 0))
  _ <- sigprocmask SIG_UNBLOCK aset
  -- sigtimedwait and sigqueue
  Right tset <- sigSetOf [SIGUSR1]
    | Left _ => putStrLn "sigSetOf failed"
  _ <- sigprocmask SIG_BLOCK tset
  sigtimedwait tset (MkTimeSpec 0 10000000) >>= \r => putStrLn ("sigtimedwait, nothing pending: " ++ errOf r)
  _ <- raise SIGUSR1
  sigtimedwait tset (MkTimeSpec 1 0) >>= \r => putStrLn ("sigtimedwait takes it: " ++ show (map (\(MkSignal n) => let MkSignal u = SIGUSR1 in n == u) r))
  sigqueue me SIGUSR1 42 >>= \r => putStrLn ("sigqueue to self: " ++ errOf r)
  sigtimedwait tset (MkTimeSpec 1 0) >>= \r => putStrLn ("sigtimedwait takes the queued one: " ++ show (map (\(MkSignal n) => let MkSignal u = SIGUSR1 in n == u) r))
  _ <- sigprocmask SIG_UNBLOCK tset
  pure ()

testInotify : IO ()
testInotify = do
  putStrLn "-- inotify"
  let dir = "TestLinux.scratch"
  _ <- removeFile (dir ++ "/new.txt")
  _ <- removeFile (dir ++ "/renamed.txt")
  _ <- removeDir dir
  Right () <- createDir dir
    | Left _ => putStrLn "createDir failed"
  Right ifd <- inotify_init IN_NONBLOCK
    | Left _ => putStrLn "inotify_init failed"
  Right wd <- inotify_add_watch ifd dir (IN_CREATE .|. IN_DELETE .|. IN_MOVED_FROM .|. IN_MOVED_TO)
    | Left _ => putStrLn "inotify_add_watch failed"
  readEvents ifd >>= \r => putStrLn ("no events yet: " ++ errOf r)
  Right (fd, name) <- mkstemp (dir ++ "/tmpXXXXXX")
    | Left _ => putStrLn "mkstemp failed"
  _ <- close fd
  _ <- unlink name
  Right evs <- readEvents ifd
    | Left _ => putStrLn "readEvents failed"
  putStrLn ("events: " ++ show (map (\e => (e.wd == wd, e.mask .&. IN_CREATE /= 0, e.mask .&. IN_DELETE /= 0)) evs))
  putStrLn ("names match: " ++ show (all (\e => isSuffixOf e.name name) evs && length evs == 2))
  Left e <- inotify_add_watch ifd (dir ++ "/missing") IN_ALL_EVENTS
    | Right _ => putStrLn "watch on a missing path: unexpectedly ok"
  putStrLn ("watch on a missing path: errno " ++ show (errnum e))
  inotify_rm_watch ifd wd >>= \r => putStrLn ("rm_watch: " ++ errOf r)
  Right gone <- readEvents ifd
    | Left _ => putStrLn "readEvents failed"
  putStrLn ("IN_IGNORED after rm_watch: " ++ show (any (\e => e.mask .&. IN_IGNORED /= 0) gone))
  _ <- close ifd
  _ <- removeDir dir
  pure ()

%foreign "CExpr:(((double (*)(double))($1))($2)),libc"
prim__callCos : AnyPtr -> Double -> PrimIO Double

testDl : IO ()
testDl = do
  putStrLn "-- dl"
  Right self <- dlopenSelf RTLD_NOW
    | Left e => putStrLn ("dlopenSelf failed: " ++ e)
  Right sym <- dlsym self "getpid"
    | Left e => putStrLn ("dlsym failed: " ++ e)
  putStrLn "dlsym getpid: found"
  dlsym self "no_such_symbol_here" >>= \r => putStrLn ("dlsym missing symbol: " ++ either (const "error") (const "found") r)
  dladdr sym >>= \r => putStrLn ("dladdr names getpid: " ++ show (map (\i => maybe False (isInfixOf "getpid") i.symbolName) r))
  Right lm <- dlopen "libm.so.6" (RTLD_LAZY .|. RTLD_LOCAL)
    | Left e => putStrLn ("dlopen libm failed: " ++ e)
  Right cosp <- dlsym lm "cos"
    | Left e => putStrLn ("dlsym cos failed: " ++ e)
  c <- primIO (prim__callCos cosp 0.0)
  putStrLn ("cos(0) through dlsym: " ++ show c)
  dlopen "libno-such-library.so" RTLD_NOW >>= \r => putStrLn ("dlopen missing library: " ++ either (const "error") (const "ok") r)
  dlclose lm >>= \r => putStrLn ("dlclose: " ++ either id (const "ok") r)
  dlclose self >>= \r => putStrLn ("dlclose self: " ++ either id (const "ok") r)

slurp : FileDesc -> IO String
slurp fd = do
  _ <- lseek fd (cast 0) SEEK_SET
  Just buf <- newBuffer 64
    | Nothing => pure "newBuffer failed"
  Right n <- Buffer.read fd buf
    | Left _ => pure "read failed"
  getString buf 0 (cast n)

testEventfd : IO ()
testEventfd = do
  putStrLn "-- eventfd"
  Right efd <- eventfd 0 EFD_NONBLOCK
    | Left e => putStrLn ("eventfd failed: " ++ show e)
  eventfdRead efd >>= \r => putStrLn ("empty counter: " ++ errOf r)
  _ <- eventfdWrite efd 5
  _ <- eventfdWrite efd 3
  eventfdRead efd >>= \r => putStrLn ("sum: " ++ show r)
  eventfdRead efd >>= \r => putStrLn ("cleared by the read: " ++ errOf r)
  _ <- close efd
  Right sem <- eventfd 2 (EFD_NONBLOCK .|. EFD_SEMAPHORE)
    | Left e => putStrLn ("eventfd failed: " ++ show e)
  eventfdRead sem >>= \r => putStrLn ("semaphore 1: " ++ show r)
  eventfdRead sem >>= \r => putStrLn ("semaphore 2: " ++ show r)
  eventfdRead sem >>= \r => putStrLn ("semaphore 3: " ++ errOf r)
  _ <- close sem
  pure ()

testMemfd : IO ()
testMemfd = do
  putStrLn "-- memfd, sendfile, splice, copy_file_range"
  Right m <- memfd_create "rc2base-test" (MFD_CLOEXEC .|. MFD_ALLOW_SEALING)
    | Left e => putStrLn ("memfd_create failed: " ++ show e)
  _ <- String.write m "hello world"
  slurp m >>= \s => putStrLn ("contents: " ++ show s)
  getSeals m >>= \r => putStrLn ("seals at first: " ++ show r)
  addSeals m (F_SEAL_WRITE .|. F_SEAL_GROW) >>= \r => putStrLn ("addSeals: " ++ errOf r)
  getSeals m >>= \r => putStrLn ("write and grow sealed: " ++ show (map (\x => (x .&. F_SEAL_WRITE) /= 0 && (x .&. F_SEAL_GROW) /= 0 && (x .&. F_SEAL_SHRINK) == 0) r))
  n <- String.write m "x"
  putStrLn ("write after the seal: " ++ either (\e => "errno " ++ show (errnum e)) show n)
  Right plain <- memfd_create "plain" 0
    | Left e => putStrLn ("memfd_create failed: " ++ show e)
  addSeals plain F_SEAL_GROW >>= \r => putStrLn ("addSeals without MFD_ALLOW_SEALING: " ++ errOf r)
  -- sendfile (an offset) into a second file, then splice into a pipe
  Right dst <- memfd_create "dst" 0
    | Left e => putStrLn ("memfd_create failed: " ++ show e)
  sendfile dst m (Just 6) 5 >>= \r => putStrLn ("sendfile: " ++ show r)
  slurp dst >>= \s => putStrLn ("sendfile copied: " ++ show s)
  Right (rd, wr) <- pipe
    | Left _ => putStrLn "pipe failed"
  splice m (Just 0) wr Nothing 5 0 >>= \r => putStrLn ("splice: " ++ show r)
  Just buf <- newBuffer 16
    | Nothing => putStrLn "newBuffer failed"
  Right k <- Buffer.read rd buf
    | Left e => putStrLn ("read failed: " ++ show e)
  getString buf 0 (cast k) >>= \s => putStrLn ("pipe has: " ++ show s)
  splice m Nothing dst Nothing 1 0 >>= \r => putStrLn ("splice between files: " ++ either (\x => "errno " ++ show (errnum x)) show r)
  _ <- close rd
  _ <- close wr
  copy_file_range m (Just 0) dst (Just 5) 5 >>= \r => putStrLn ("copy_file_range: " ++ show r)
  slurp dst >>= \s => putStrLn ("after copy_file_range: " ++ show s)
  for_ [m, plain, dst] $ \f => close f

testPrctl : IO ()
testPrctl = do
  putStrLn "-- prctl"
  setThreadName "rc2base-test" >>= \r => putStrLn ("setThreadName: " ++ errOf r)
  getThreadName >>= \r => putStrLn ("getThreadName: " ++ show r)
  setParentDeathSignal (Just SIGUSR1) >>= \r => putStrLn ("setParentDeathSignal: " ++ errOf r)
  getParentDeathSignal >>= \r => putStrLn ("getParentDeathSignal: " ++ show (map (map (cast {to=Int32})) r))
  setParentDeathSignal Nothing >>= \r => putStrLn ("clear: " ++ errOf r)
  getParentDeathSignal >>= \r => putStrLn ("cleared: " ++ show (map (map (cast {to=Int32})) r))
  setChildSubreaper True >>= \r => putStrLn ("setChildSubreaper: " ++ errOf r)
  getChildSubreaper >>= \r => putStrLn ("getChildSubreaper: " ++ show r)
  setDumpable True >>= \r => putStrLn ("setDumpable: " ++ errOf r)
  getDumpable >>= \r => putStrLn ("getDumpable: " ++ show r)
  setNoNewPrivs >>= \r => putStrLn ("setNoNewPrivs: " ++ errOf r)
  getNoNewPrivs >>= \r => putStrLn ("no_new_privs after: " ++ show r)

testStatx : IO ()
testStatx = do
  putStrLn "-- statx"
  Right sx <- statx Nothing "/" 0 STATX_BASIC_STATS
    | Left e => putStrLn ("statx failed: " ++ show e)
  Right st <- stat "/"
    | Left e => putStrLn ("stat failed: " ++ show e)
  putStrLn ("statx agrees with stat: " ++ show (sx.stxIno == st.stIno && sx.stxSize == cast st.stSize && sx.stxNlink == cast st.stNlink
                                                && sx.stxMtime == st.stMtime && cast sx.stxMode == st.stMode))
  putStrLn ("basic stats are valid: " ++ show (hasMask STATX_BASIC_STATS sx.stxMask))
  putStrLn ("a directory: " ++ show ((cast {to=Bits32} sx.stxMode .&. S_IFMT) == S_IFDIR))
  statx Nothing "/no/such/path" 0 STATX_BASIC_STATS >>= \r => putStrLn ("missing path: " ++ errOf r)
  Right m <- memfd_create "statx" 0
    | Left e => putStrLn ("memfd_create failed: " ++ show e)
  _ <- String.write m "hello world"
  fstatx m STATX_SIZE >>= \r => putStrLn ("fstatx size: " ++ show (map (\x => x.stxSize) r))
  _ <- close m
  pure ()

testRandom : IO ()
testRandom = do
  putStrLn "-- getrandom"
  Just b1 <- newBuffer 16
    | Nothing => putStrLn "newBuffer failed"
  Just b2 <- newBuffer 16
    | Nothing => putStrLn "newBuffer failed"
  getrandom b1 0 >>= \r => putStrLn ("filled: " ++ show r)
  _ <- getrandom b2 0
  x <- bufferData b1
  y <- bufferData b2
  putStrLn ("two draws differ: " ++ show (x /= y))
  Right a <- getrandomBits64 0
    | Left e => putStrLn ("getrandomBits64 failed: " ++ show e)
  Right b <- getrandomBits64 0
    | Left e => putStrLn ("getrandomBits64 failed: " ++ show e)
  putStrLn ("two numbers differ: " ++ show (a /= b))

testProcess : IO ()
testProcess = do
  putStrLn "-- gettid, pidfd, affinity"
  tid <- gettid
  pid <- getpid
  putStrLn ("tid is pid in the main thread: " ++ show (cast {to=Int32} tid == cast {to=Int32} pid))
  ignore $ fflush stdout
  Right c <- fork
    | Left e => putStrLn ("fork failed: " ++ show e)
  if cast {to=Int32} c == 0
    then sleep 30 >> exitNow 0
    else pure ()
  Right pfd <- pidfd_open c 0
    | Left e => putStrLn ("pidfd_open: errno " ++ show (errnum e))
  poll [(pfd, POLLIN)] 0 >>= \r => putStrLn ("child running: " ++ show r)
  pidfd_send_signal pfd SIGKILL >>= \r => putStrLn ("pidfd_send_signal: " ++ errOf r)
  poll [(pfd, POLLIN)] 5000 >>= \r => putStrLn ("child gone: " ++ show (map (map (\e => (e .&. POLLIN) /= 0)) r))
  _ <- waitpid c 0
  _ <- close pfd
  Right cpus <- getAffinity Nothing
    | Left e => putStrLn ("getAffinity: errno " ++ show (errnum e))
  putStrLn ("allowed CPUs, not empty: " ++ show (not (null cpus)))
  sched_getcpu >>= \r => putStrLn ("current CPU is allowed: " ++ show (map (\n => elem (cast n) cpus) r))
  setAffinity Nothing cpus >>= \r => putStrLn ("setAffinity to the same set: " ++ errOf r)

eventsOf : FileDesc -> Either Errno (List ReadyEvent) -> String
eventsOf efd (Right [ev]) = "one event for the eventfd: " ++ show (ev.fd == efd.rawfd) ++ ", readable: " ++ show (hasEvent EPOLLIN ev.events)
eventsOf efd (Right evs) = show (length evs) ++ " events"
eventsOf efd (Left e) = "errno " ++ show (errnum e)

testEpoll : IO ()
testEpoll = do
  putStrLn "-- epoll"
  Right ep <- epollCreate 4
    | Left e => putStrLn ("epollCreate failed: " ++ show e)
  Right ep2 <- epollCreate 4
    | Left e => putStrLn ("epollCreate failed: " ++ show e)
  Right efd <- eventfd 0 (EFD_NONBLOCK .|. EFD_CLOEXEC)
    | Left e => putStrLn ("eventfd failed: " ++ show e)
  epollWait ep 0 >>= \r => putStrLn ("nothing watched: " ++ show (map length r))
  epollAdd ep efd EPOLLIN >>= \r => putStrLn ("add: " ++ errOf r)
  epollAdd ep efd EPOLLIN >>= \r => putStrLn ("add twice: errno " ++ either (show . errnum) (const "ok") r)
  epollAdd ep2 efd EPOLLIN >>= \r => putStrLn ("add to the second epoll: " ++ errOf r)
  epollWait ep 0 >>= \r => putStrLn ("not ready: " ++ show (map length r))
  _ <- eventfdWrite efd 1
  epollWait ep 1000 >>= \r => putStrLn (eventsOf efd r)
  epollWait ep2 1000 >>= \r => putStrLn ("the other epoll: " ++ eventsOf efd r)
  -- level-triggered: still ready until the counter is read
  epollWait ep 0 >>= \r => putStrLn ("still ready: " ++ show (map length r))
  _ <- eventfdRead efd
  epollWait ep 0 >>= \r => putStrLn ("after the read: " ++ show (map length r))
  epollMod ep efd (EPOLLIN .|. EPOLLOUT) >>= \r => putStrLn ("mod: " ++ errOf r)
  epollWait ep 0 >>= \r => putStrLn ("writable now: " ++ show (map (map (\ev => hasEvent EPOLLOUT ev.events)) r))
  epollDel ep efd >>= \r => putStrLn ("del: " ++ errOf r)
  epollDel ep efd >>= \r => putStrLn ("del twice: errno " ++ either (show . errnum) (const "ok") r)
  epollWait ep 0 >>= \r => putStrLn ("after del: " ++ show (map length r))
  _ <- close efd
  epollClose ep >>= \r => putStrLn ("close: " ++ errOf r)
  epollClose ep2 >>= \r => putStrLn ("close the second: " ++ errOf r)

main : IO ()
main = do
  Right (rd, wr) <- pipe2 (O_CLOEXEC .|. O_NONBLOCK)
    | Left _ => putStrLn "pipe2 failed"
  getFdFlags rd >>= \r => putStrLn ("cloexec on the read end: " ++ show r)
  getFdFlags wr >>= \r => putStrLn ("cloexec on the write end: " ++ show r)
  Right fl <- getStatusFlags rd
    | Left _ => putStrLn "getStatusFlags failed"
  putStrLn ("nonblock on the read end: " ++ show ((fl .&. O_NONBLOCK) /= 0))
  _ <- write wr "ping"
  _ <- close wr
  _ <- close rd
  Right (rd2, wr2) <- pipe2 0
    | Left _ => putStrLn "pipe2 failed"
  getFdFlags rd2 >>= \r => putStrLn ("no flags: " ++ show r)
  _ <- close rd2
  _ <- close wr2
  testClock
  testTimerfd
  testSignalfd
  testInotify
  testDl
  testEventfd
  testEpoll
  testMemfd
  testPrctl
  testStatx
  testRandom
  testProcess
  putStrLn "done"
