||| Signals for `Control.Task`: wait for one on the scheduler through a `signalfd`
||| instead of a handler. Linux only, `--cg rc2`.
|||
||| A signal that is not blocked is delivered the ordinary way, and its default
||| action (usually ending the process) runs. `awaitSignals` blocks the signals
||| in the calling thread, which is enough when no worker thread exists yet. With
||| workers, call `blockSignals` before the scheduler starts, so that every
||| thread inherits the mask. A signal sent to a thread (`raise`) is seen only by
||| a `signalfd` read on that thread; one sent to the process (`kill`) by any.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Control.Task.Signal

import Control.Task
import Data.Bits
import System.Linux.Epoll
import System.Linux.Signalfd
import System.Posix.Errno
import System.Posix.FileDesc
import System.Posix.Signal

%default covering

blockSet : SigSet -> IO (Either Errno ())
blockSet set = map (map (const ())) (sigprocmask SIG_BLOCK set)

||| Block the signals in the calling thread (and in the threads it creates
||| afterwards), so that they wait to be taken from a `signalfd`.
export
blockSignals : List Signal -> IO (Either Errno ())
blockSignals sigs = do
  Right set <- sigSetOf sigs
    | Left e => pure (Left e)
  blockSet set

openSignalfd : List Signal -> IO (Either Errno FileDesc)
openSignalfd sigs = do
  Right set <- sigSetOf sigs
    | Left e => pure (Left e)
  Right () <- blockSet set
    | Left e => pure (Left e)
  signalfd set (SFD_NONBLOCK .|. SFD_CLOEXEC)

closeQuietly : Either Errno FileDesc -> IO ()
closeQuietly (Right fd) = ignore (close fd)
closeQuietly (Left _) = pure ()

||| Wait for one of the signals and take it. The signals stay blocked afterwards,
||| also when the call fails. A signal raised while blocked before the call is
||| taken at once. The signal is read only after the wait has won, so a wait that
||| is given up leaves it pending for the next one. Several waits for the same
||| signal share it: one takes it and the others go on waiting.
export
awaitSignals : List Signal -> Task (Either Errno SignalInfo)
awaitSignals sigs = do
  opened <- handoff (\_, done => noCancel <$ (openSignalfd sigs >>= done)) closeQuietly
  case opened of
    Left e => pure (Left e)
    Right fd => finally (\_ => ignore (close fd)) (loop fd)
  where
    loop : FileDesc -> Task (Either Errno SignalInfo)
    loop fd = do
      ev <- awaitEvents fd EPOLLIN
      if not (hasEvent EPOLLIN ev)
         then pure (Left EBADF)
         else do
           Left e <- liftIO (readSignal fd)
             | Right info => pure (Right info)
           if e == EAGAIN then loop fd else pure (Left e)

||| Run the task until one of the signals comes. `Left` is the outcome of the
||| wait (the signal, or the error that ended it) and the task is given up;
||| `Right` is the task's result.
export
untilSignals : List Signal -> Task a -> Task (Either (Either Errno SignalInfo) a)
untilSignals sigs t = race (awaitSignals sigs) t
