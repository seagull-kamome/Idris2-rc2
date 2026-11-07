||| Child processes for `Control.Task`: start a program with a pipe to its standard
||| input and one from its standard output, wait for it to end without blocking the
||| scheduler, send it signals, and collect its output. Linux only (`pidfd_open`,
||| `posix_spawn`), build with `IDRIS2_CFLAGS=-D_GNU_SOURCE`.
|||
||| * A child is waited for through a `pidfd` on the scheduler's `epoll`, and
|||   reaped by its own process ID, never with `wait`: other children are not
|||   touched. Without `pidfd` (a kernel before 5.3, or a sandbox that forbids
|||   it) a worker thread waits for it, so the scheduler has to be started with
|||   workers. A process that ignores `SIGCHLD` has its children reaped by the
|||   system, and they cannot be waited for.
||| * The child is a process group of its own (`spawnStdio`): a Ctrl-C at the
|||   terminal does not reach it, and it outlives this process unless it is
|||   closed. `cleanup` kills the whole group, so a program the child started
|||   goes with it, if the child is still unreaped; `signalChild` signals the child
|||   only.
||| * The standard error of the child is ours (`spawnStdio` does not redirect it).
||| * `spawn` calls `ignoreSigpipe`, so that writing to a child that has gone is
|||   the error `EPIPE` and not the end of the process; this is for the whole
|||   process.
||| * `withChild` ends the child with `SIGKILL` if it is still running, waits for
|||   it, and closes the pipes. The wait is a blocking `waitpid` on the thread of
|||   the scheduler: a process that does not die at `SIGKILL` (stuck in the kernel)
|||   stops the scheduler.
||| * Do not close a `Child` (leave `withChild`) while another task is waiting
|||   for it: give those tasks up first.
module System.Posix.Async.Process

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Control.Task
import Data.Buffer
import Data.IORef
import Data.Maybe
import Data.String.RC2
import System.Linux.Epoll
import System.Linux.Pipe
import System.Linux.Process
import System.Posix.Async.File as A
import System.Posix.Errno
import System.Posix.File
import System.Posix.FileDesc
import System.Posix.Process as P
import System.Posix.Signal
import System.Posix.Spawn

%default covering

||| A running or ended child process.
export
record Child where
  constructor MkChild
  processId : ProcessID
  inHandle : Handle
  outHandle : Handle
  pidfd : Maybe Handle
  status : IORef (Maybe ProcessStatus)
  worker : IORef Bool

||| The process ID of the child.
export
(.pid) : Child -> ProcessID
(.pid) = processId

||| What we write goes to the standard input of the child; closing it ends the
||| input.
export
(.stdin) : Child -> Handle
(.stdin) = inHandle

||| What the child writes to its standard output.
export
(.stdout) : Child -> Handle
(.stdout) = outHandle

-------------------------------------------------------------------------------
-- Starting

closeAll : List FileDesc -> IO ()
closeAll = traverse_ (\fd => ignore (System.Posix.FileDesc.close fd))

-- `waitpid` for the process itself (not `WNOHANG`), again after an `EINTR`.
waitpidRetry : ProcessID -> IO (Either Errno (ProcessID, ProcessStatus))
waitpidRetry pid = do
  r <- P.waitpid pid 0
  case r of
    Left e => if e == EINTR then waitpidRetry pid else pure r
    Right _ => pure r

-- A pidfd of the child. `Nothing` when the system has none (`ENOSYS`, or `EPERM`
-- from a sandbox); another failure (no descriptor left, no memory) is an error.
pidfdOf : ProcessID -> IO (Either Errno (Maybe Handle))
pidfdOf pid = do
  r <- pidfd_open pid 0
  case r of
    Left e => pure (if e == ENOSYS || e == EPERM then Right Nothing else Left e)
    Right fd => do
      h <- ownNow fd
      case h of
        Left e => Left e <$ System.Posix.FileDesc.close fd
        Right handle => pure (Right (Just handle))

-- The parent's ends of the pipes and the pidfd, as handles. Nothing is left open
-- on failure.
adoptEnds : ProcessID -> (inW, outR : FileDesc) -> IO (Either Errno Child)
adoptEnds pid inW outR = do
  Right hin <- ownNow inW
    | Left e => closeAll [inW, outR] *> pure (Left e)
  Right hout <- ownNow outR
    | Left e => closeNow hin *> closeAll [outR] *> pure (Left e)
  Right pfd <- pidfdOf pid
    | Left e => closeNow hin *> closeNow hout *> pure (Left e)
  st <- newIORef Nothing
  w <- newIORef False
  pure (Right (MkChild pid hin hout pfd st w))

-- Reap the child if it has ended; `Nothing` while it still runs.
reap : Child -> IO (Either Errno (Maybe ProcessStatus))
reap c = do
  known <- readIORef c.status
  case known of
    Just st => pure (Right (Just st))
    Nothing => do
      r <- P.waitpid c.processId WNOHANG
      case r of
        Left e => if e == EINTR then reap c else pure (Left e)
        Right (got, st) =>
          if cast got == the Int32 0
             then pure (Right Nothing)
             else Right (Just st) <$ writeIORef c.status (Just st)

-- Kill the process group of the child if it is still unreaped (the group id is
-- held by the unreaped child), wait for it, close what is open.
cleanup : Child -> IO ()
cleanup c = do
  known <- readIORef c.status
  when (isNothing known) $ do
    ignore (P.kill (MkProcessID (negate (the Int32 (cast c.processId)))) SIGKILL)
    ignore (P.kill c.processId SIGKILL)
    r <- waitpidRetry c.processId
    case r of
      Right (_, st) => writeIORef c.status (Just st)
      Left _ => pure ()
  closeNow c.inHandle
  closeNow c.outHandle
  traverse_ closeNow c.pidfd

-- Make the child and its pipes. The ends the child gets are not `O_NONBLOCK`
-- (the flag belongs to the open file, and the child would see it).
made : (path, cwd : String) -> (argv, envp : List String) -> IO (Either Errno Child)
made path cwd argv envp = do
  ignoreSigpipe
  Right (inR, inW) <- pipe2 O_CLOEXEC
    | Left e => pure (Left e)
  Right (outR, outW) <- pipe2 O_CLOEXEC
    | Left e => closeAll [inR, inW] *> pure (Left e)
  r <- spawnStdio path cwd argv envp inR outW
  closeAll [inR, outW]
  case r of
    Left e => closeAll [inW, outR] *> pure (Left e)
    Right pid => do
      c <- adoptEnds pid inW outR
      case c of
        Right child => pure (Right child)
        Left e => do
          ignore (P.kill pid SIGKILL)
          ignore (waitpidRetry pid)
          pure (Left e)

||| Start the program at `path` (no `PATH` lookup; a relative `path` is taken from
||| `cwd`, where the program starts) with `argv` (the program name first) and
||| exactly the environment `envp` (`NAME=value`). `Left` if it cannot be started
||| (`ENOENT`, `EACCES`, ...). A task given up while the child is being made
||| ends it.
export
spawn : (path, cwd : String) -> (argv, envp : List String) -> Task (Either Errno Child)
spawn path cwd argv envp = handoff start undo
  where
    undo : Either Errno Child -> IO ()
    undo (Right c) = cleanup c
    undo (Left _) = pure ()

    start : Env -> Completion (Either Errno Child) -> IO Cancel
    start _ done = noCancel <$ (made path cwd argv envp >>= done)

||| Run the task and then end the child (`SIGKILL` if it is still running, wait
||| for it) and close its pipes, also when the task is given up.
export
withChild : Child -> Task a -> Task a
withChild c = finally (\_ => cleanup c)

-------------------------------------------------------------------------------
-- Waiting and signals

-- Without a pidfd: a worker waits, one at a time for a child. The worker keeps the
-- status when it is done, also if the task that started it has been given up by
-- then; the tasks that come meanwhile wait for the status to appear.
data Turn = Known ProcessStatus | Busy | Mine

takeTurn : Child -> IO Turn
takeTurn c = do
  known <- readIORef c.status
  case known of
    Just st => pure (Known st)
    Nothing => do
      running <- readIORef c.worker
      if running then pure Busy else Mine <$ writeIORef c.worker True

waitOnWorker : Child -> Task (Either Errno ProcessStatus)
waitOnWorker c = do
  turn <- onReactor (takeTurn c)
  case turn of
    Known st => pure (Right st)
    Busy => sleepFor 5 *> waitOnWorker c
    Mine => Async $ \env, done => noCancel <$ env.offload (do
      r <- waitpidRetry c.processId
      env.post (do
        for_ r (\(_, st) => writeIORef c.status (Just st))
        writeIORef c.worker False
        done (map snd r)))

||| Wait until the child has ended and reap it; the status is kept, so that it
||| can be asked for again.
export
waitChild : Child -> Task (Either Errno ProcessStatus)
waitChild c = case c.pidfd of
  Just h => viaPidfd h
  Nothing => waitOnWorker c
  where
    viaPidfd : Handle -> Task (Either Errno ProcessStatus)
    viaPidfd h = do
      r <- onReactor (reap c)
      case r of
        Left e => pure (Left e)
        Right (Just st) => pure (Right st)
        Right Nothing => awaitReadable h.descriptor *> viaPidfd h

||| Send a signal to the child. `ESRCH` if it has been reaped already.
export
signalChild : Child -> Signal -> Task (Either Errno ())
signalChild c sig = onReactor $ do
  known <- readIORef c.status
  case known of
    Just _ => pure (Left ESRCH)
    Nothing => case c.pidfd of
      Just h => pidfd_send_signal h.descriptor sig
      Nothing => P.kill c.processId sig

||| Ask the child to end with `SIGTERM`, wait `grace` milliseconds for it, then
||| end it with `SIGKILL`; the status either way.
export
terminate : Child -> (grace : Nat) -> Task (Either Errno ProcessStatus)
terminate c grace = do
  _ <- signalChild c SIGTERM
  t <- now
  r <- timeoutAt (t + grace) (waitChild c)
  case r of
    Just st => pure st
    Nothing => do
      _ <- signalChild c SIGKILL
      waitChild c

-------------------------------------------------------------------------------
-- Collecting the output

-- Write the input to the child, then close its standard input. An error (the
-- child has gone: `EPIPE`) ends the writing, and is not the caller's.
feed : Child -> Buffer -> Int -> Task ()
feed c buf n = do
  when (n > 0) (ignore (A.writeAll c.inHandle buf 0 n))
  A.close c.inHandle

||| Run a program with `input` as its standard input and collect what it writes to
||| its standard output (until it closes it) and its status. The child is ended
||| if the task is given up, and also if the output cannot be read. The standard
||| error is not collected. A program the child started that keeps the standard
||| output open keeps the call waiting, as with `popen`; one that keeps the
||| standard input open keeps the writing of the input going. All of the output is
||| held in memory (a few times its size while it is read). `EFBIG` for an input
||| of 2 GiB or more.
export
captureOutput : (path, cwd : String) -> (argv, envp : List String) -> (input : String)
             -> Task (Either Errno (ProcessStatus, String))
captureOutput path cwd argv envp input =
  if byteLength input > 2147483647 then pure (Left EFBIG) else do
    let n = byteLength input
    Just buf <- onReactor (newBuffer (max 1 n))
      | Nothing => pure (Left ENOMEM)
    onReactor (setString buf 0 input)
    Right c <- spawn path cwd argv envp
      | Left e => pure (Left e)
    withChild c $ do
      _ <- fork (feed c buf n)
      out <- A.readString c.outHandle
      case out of
        Left e => do
          _ <- signalChild c SIGKILL
          _ <- waitChild c
          pure (Left e)
        Right o => do
          st <- waitChild c
          pure (map (\s => (s, o)) st)
