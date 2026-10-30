||| Sockets for `Control.Task`: `accept`, `connect`, `recv` and `send` that wait for
||| the descriptor on the scheduler's epoll instead of blocking a thread. A `Sock`
||| is non-blocking; a call that would block waits for readiness and tries
||| again. Needs no liburing. Linux/POSIX, `--cg rc2`.
module Network.Async

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Control.Task
import Data.Bits
import Data.Buffer
import Data.IORef
import Data.String.FFI
import public Network.Address
import System.FFI
import System.Linux.Epoll
import System.Posix.Errno
import System.Posix.Fcntl
import System.Posix.File
import System.Posix.FileDesc
import System.Posix.Socket as Posix

%default covering

||| A non-blocking socket, listening or connected.
export
record Sock where
  constructor MkSock
  fd : FileDesc
  open_ : IORef Bool
  peerAddr : Maybe String

||| The descriptor, for `Control.Task.awaitReadable` and the like.
export
(.descriptor) : Sock -> FileDesc
(.descriptor) = fd

||| The address of the other end, as text (`192.0.2.1`), for a socket made by
||| `accept`; `Nothing` for one made by `listen` or `connect`.
export
(.peer) : Sock -> Maybe String
(.peer) = peerAddr

||| Close the socket. Closing again does nothing, so it is safe to call from a
||| cleanup as well as from the code that used the socket. It is not safe to call
||| from two threads at once: inside a task use `onReactor (close s)` (as
||| `withSock` does) when the scheduler runs actions on several threads.
export
close : Sock -> IO ()
close s = do
  isOpen <- readIORef s.open_
  when isOpen $ do
    writeIORef s.open_ False
    ignore (System.Posix.FileDesc.close s.fd)

||| Tell the peer that nothing more will be sent (`shutdown(SHUT_WR)`), while
||| what it sends can still be read.
export
shutdownWrite : Sock -> IO ()
shutdownWrite s = ignore (Posix.shutdown s.fd ShutWrite)

||| Run the task and close the socket when it ends or is given up (its scope
||| is cancelled, a `race` lost). The close on cancellation is what stops a
||| server from leaking the connections it was serving. Closing is done as the
||| task starts being given up or ends, on the thread of the scheduler.
export
withSock : Sock -> Task a -> Task a
withSock s = finally (\_ => close s)

setNonBlocking : FileDesc -> IO (Either Errno ())
setNonBlocking fd = do
  Right flags <- getStatusFlags fd
    | Left e => pure (Left e)
  setStatusFlags fd (flags .|. O_NONBLOCK)

adoptFrom : Maybe String -> FileDesc -> IO (Either Errno Sock)
adoptFrom peer fd = do
  r <- setNonBlocking fd
  case r of
    Left e => ignore (System.Posix.FileDesc.close fd) *> pure (Left e)
    Right () => do
      -- close-on-exec, so that a program started later does not inherit the
      -- connection (there is a short gap between the system call that made the
      -- descriptor and here; a `fork` of another thread in it still inherits it)
      ignore (setFdFlags fd FD_CLOEXEC)
      (\open_ => Right (MkSock fd open_ peer)) <$> newIORef True

adopt : FileDesc -> IO (Either Errno Sock)
adopt = adoptFrom Nothing


||| A socket listening on `bindAddr` (loopback by default) and `port`.
export
listen : {default loopbackAddress bindAddr : Address}
      -> (port : Int) -> IO (Either Errno Sock)
listen {bindAddr} port = if not (validPort port) then pure (Left EINVAL) else do
  Right fd <- Posix.socket AF_INET SOCK_STREAM 0
    | Left e => pure (Left e)
  r <- prepare fd
  case r of
    Right () => adopt fd
    Left e => ignore (System.Posix.FileDesc.close fd) *> pure (Left e)
  where
    prepare : FileDesc -> IO (Either Errno ())
    prepare fd = do
      Right () <- setSockOptInt fd SOL_SOCKET SO_REUSEADDR 1
        | Left e => pure (Left e)
      Right () <- Posix.bind fd (toSockAddr bindAddr port)
        | Left e => pure (Left e)
      Posix.listen fd 128

||| Connect to an IPv4 address and wait until the connection is made (a host
||| name would need a blocking lookup, so it is not accepted). Like `accept`, the socket is handed over with `handoff`; a
||| connect that is given up while it is under way closes its socket.
export
connect : Address -> (port : Int) -> Task (Either Errno Sock)
connect addr port = handoff start (either (\_ => pure ()) close)
  where
    target : SockAddr
    target = toSockAddr addr port

    -- A connection under way is done when the descriptor is writable; how it
    -- went is the pending error of the socket.
    finish : Sock -> IORef Bool -> Completion (Either Errno Sock) -> IO ()
    finish s settled done = do
      writeIORef settled True
      e <- either id id <$> socketError s.fd
      if e == MkErrno 0 then done (Right s) else close s *> done (Left e)

    giveUp : Sock -> IORef Bool -> IORef Cancel -> IO ()
    giveUp s settled watching = do
      settledAlready <- readIORef settled
      unless settledAlready (join (map runCancel (readIORef watching)) *> close s)

    waiting : Env -> Sock -> Completion (Either Errno Sock) -> IO Cancel
    waiting env s done = do
      settled <- newIORef False
      watching <- newIORef noCancel
      env.watchFd s.fd EPOLLOUT (\_ => finish s settled done) >>= writeIORef watching
      pure (MkCancel (giveUp s settled watching))

    start : Env -> Completion (Either Errno Sock) -> IO Cancel
    start env done = if not (validPort port) then noCancel <$ done (Left EINVAL) else do
      opened <- Posix.socket AF_INET SOCK_STREAM 0
      case opened of
        Left e => noCancel <$ done (Left e)
        Right fd => do
          adopted <- adopt fd
          case adopted of
            Left e => noCancel <$ done (Left e)
            Right s => do
              started <- Posix.connect fd target
              case started of
                Right () => noCancel <$ done (Right s)
                Left e =>
                  if elem e [EINPROGRESS, EINTR] then waiting env s done
                  else close s *> (noCancel <$ done (Left e))

||| One attempt at a system call that answers -1 and sets `errno` on failure.
export
attempt : PrimIO Int -> IO (Either Errno Int)
attempt call = do
  n <- primIO call
  if n >= 0 then pure (Right n) else Left <$> errno

||| `retrying` for a call that gives its own result.
export
retryingIO : (wait : Task a) -> IO (Either Errno Int) -> Task (Either Errno Int)
retryingIO wait call = do
  r <- onReactor call
  case r of
    Left e => if e == EAGAIN then wait *> retryingIO wait call
              else if e == EINTR then retryingIO wait call
              else pure r
    Right _ => pure r

||| Repeat the call, waiting with `wait` when it would block (`EAGAIN`).
export
retrying : (wait : Task a) -> PrimIO Int -> Task (Either Errno Int)
retrying wait call = retryingIO wait (attempt call)

||| The next connection. Waits until one arrives. The socket is handed over with
||| `handoff`: if the task is given up in the step between the connection being
||| accepted and the task going on, the socket is closed, not leaked.
export
accept : Sock -> Task (Either Errno Sock)
accept l = handoff start (either (\_ => pure ()) close)
  where
    -- `accept` on a non-blocking descriptor does not wait, so it is called on
    -- the thread of the scheduler; when there is nothing to accept, the
    -- descriptor is watched and the call tried again.
    try : Env -> IORef Cancel -> Completion (Either Errno Sock) -> IO ()
    try env watching done = do
      r <- Posix.accept l.fd
      case r of
        Right (conn, addr) => do
          peer <- maybe (pure Nothing) addressText addr
          adoptFrom peer conn >>= done
        Left e => if e == EAGAIN
                    then env.watchFd l.fd EPOLLIN (\_ => try env watching done) >>= writeIORef watching
                    else if e == EINTR then try env watching done else done (Left e)

    start : Env -> Completion (Either Errno Sock) -> IO Cancel
    start env done = do
      watching <- newIORef noCancel
      try env watching done
      pure (MkCancel (join (map runCancel (readIORef watching))))

-- The call, if `buf[off .. off+len)` lies inside the buffer and is not empty;
-- `EINVAL` otherwise. The C call would read or write outside the buffer, and a
-- `recv` of no bytes would answer 0, which means the peer has closed.
within : Buffer -> (off, len : Int) -> Task (Either Errno Int) -> Task (Either Errno Int)
within buf off len call = do
  size <- onReactor (rawSize buf)
  if off >= 0 && len > 0 && len <= size - off then call else pure (Left EINVAL)

||| Read up to `len` bytes into `buf[off ..]` (`len` must be positive and the
||| range inside the buffer, else `EINVAL`). Waits until there is something to
||| read. `Right 0` means the peer closed the connection.
export
recv : Sock -> Buffer -> (off, len : Int) -> Task (Either Errno Int)
recv s buf off len = within buf off len (retryingIO (awaitReadable s.fd) (Posix.recv s.fd buf off len 0))

||| Write some of `buf[off .. off+len)`; the result is how many bytes went out
||| (`EINVAL` for an empty range or one outside the buffer).
export
send : Sock -> Buffer -> (off, len : Int) -> Task (Either Errno Int)
send s buf off len = within buf off len (retryingIO (awaitWritable s.fd) (Posix.send s.fd buf off len MSG_NOSIGNAL))

||| Write all of `buf[off .. off+len)`; nothing to do for an empty range.
export
sendAll : Sock -> Buffer -> (off, len : Int) -> Task (Either Errno ())
sendAll s buf off len =
  if len <= 0 then pure (Right ()) else do
    r <- send s buf off len
    case r of
      Left e => pure (Left e)
      Right n => sendAll s buf (off + n) (len - n)

-- One non-blocking attempt, on the thread of the scheduler: `EAGAIN` when the
-- call would block or was interrupted.
once : IO (Either Errno Int) -> Task (Either Errno Int)
once call = do
  r <- onReactor call
  pure $ case r of
    Left e => if e == EINTR then Left EAGAIN else r
    Right _ => r

||| `recv` that gives up at the time `t` (`Nothing`: the time ran out). The timer and
||| the race it needs are made only when the call would block: data that is already
||| there costs none of them.
export
recvUntil : Time -> Sock -> Buffer -> (off, len : Int) -> Task (Maybe (Either Errno Int))
recvUntil t s buf off len = do
  first <- within buf off len (once (Posix.recv s.fd buf off len 0))
  case first of
    Left e => if e == EAGAIN then timeoutAt t (recv s buf off len) else pure (Just first)
    Right _ => pure (Just first)

||| `sendAll` that gives up at the time `t`, with the same economy as `recvUntil`.
export
sendAllUntil : Time -> Sock -> Buffer -> (off, len : Int) -> Task (Maybe (Either Errno ()))
sendAllUntil t s buf off len =
  if len <= 0 then pure (Just (Right ())) else do
    first <- within buf off len (once (Posix.send s.fd buf off len MSG_NOSIGNAL))
    case first of
      Left e => if e == EAGAIN then timeoutAt t (sendAll s buf off len) else pure (Just (Left e))
      Right n => if n >= len then pure (Just (Right ()))
                 else timeoutAt t (sendAll s buf (off + n) (len - n))

||| Read and throw away what the peer sends, until it closes, an error, or
||| `limit` bytes. It has no time limit of its own: wrap it in `timeoutAt`. Closing a socket with unread bytes makes the system reset the
||| connection, and the peer may lose what was sent before; `shutdownWrite`, then
||| `discard` (against a deadline), then `close` is a lingering close.
export
discard : Sock -> (limit : Int) -> Task ()
discard s limit = do
  Just buf <- liftIO (newBuffer 4096)
    | Nothing => pure ()
  go buf limit
  where
    go : Buffer -> Int -> Task ()
    go buf left = when (left > 0) $ do
      r <- recv s buf 0 (min 4096 left)
      case r of
        Right n => when (n > 0) (go buf (left - n))
        Left _ => pure ()
