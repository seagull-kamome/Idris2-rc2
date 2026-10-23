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
import Network.Socket
import Network.Socket.Data
import System.Linux.Epoll
import System.Posix.Errno
import System.Posix.Fcntl
import System.Posix.File
import System.Posix.FileDesc

%default covering

%foreign "CExpr:((int)recv($1, (char *)($2) + ($3), (size_t)($4), 0)),libc,sys/socket.h"
prim__recv : Int32 -> Buffer -> Int -> Int -> PrimIO Int

-- MSG_NOSIGNAL: a peer that went away is an `EPIPE` result, not SIGPIPE.
%foreign "CExpr:((int)send($1, (char *)($2) + ($3), (size_t)($4), MSG_NOSIGNAL)),libc,sys/socket.h"
prim__send : Int32 -> Buffer -> Int -> Int -> PrimIO Int

%foreign "CExpr:((int)accept($1, NULL, NULL)),libc,sys/socket.h"
prim__accept : Int32 -> PrimIO Int

%foreign "CExpr:((int)setsockopt($1, SOL_SOCKET, SO_REUSEADDR, (int[]){1}, sizeof(int))),libc,sys/socket.h"
prim__reuseAddr : Int32 -> PrimIO Int32

%foreign "CExpr:(shutdown($1, SHUT_WR)),libc,sys/socket.h"
prim__shutdownWrite : Int32 -> PrimIO Int32

%foreign "CExpr:((int)({ int e = 0; socklen_t l = sizeof e; getsockopt($1, SOL_SOCKET, SO_ERROR, &e, &l) == 0 ? e : errno; })),libc,sys/socket.h"
prim__pendingError : Int32 -> PrimIO Int32

%foreign "CExpr:(close($1)),libc,unistd.h"
prim__close : Int32 -> PrimIO Int32

||| A non-blocking socket, listening or connected.
export
record Sock where
  constructor MkSock
  fd : FileDesc
  open_ : IORef Bool

||| The descriptor, for `Control.Task.awaitReadable` and the like.
export
(.descriptor) : Sock -> FileDesc
(.descriptor) = fd

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
    ignore (primIO (prim__close s.fd.rawfd))

||| Tell the peer that nothing more will be sent (`shutdown(SHUT_WR)`), while
||| what it sends can still be read.
export
shutdownWrite : Sock -> IO ()
shutdownWrite s = ignore (primIO (prim__shutdownWrite s.fd.rawfd))

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

adopt : Int32 -> IO (Either Errno Sock)
adopt n = case mkFileDesc n of
  Nothing => pure (Left EBADF)
  Just fd => do
    r <- setNonBlocking fd
    case r of
      Left e => ignore (primIO (prim__close n)) *> pure (Left e)
      Right () => Right . MkSock fd <$> newIORef True

||| A socket listening on `bindAddr` (loopback by default) and `port`.
export
listen : {default (IPv4Addr 127 0 0 1) bindAddr : SocketAddress}
      -> Port -> IO (Either Errno Sock)
listen {bindAddr} port = do
  Right sock <- socket AF_INET Stream 0
    | Left e => pure (Left (MkErrno (cast e)))
  r <- prepare sock
  case r of
    Left e => Network.Socket.close sock *> pure (Left e)
    Right () => adopt (cast sock.descriptor)
  where
    prepare : Socket -> IO (Either Errno ())
    prepare sock = do
      0 <- primIO (prim__reuseAddr (cast sock.descriptor))
        | _ => Left <$> errno
      0 <- bind sock (Just bindAddr) port
        | e => pure (Left (MkErrno (cast e)))
      listened <- Network.Socket.listen sock
      pure (if listened == 0 then Right () else Left (MkErrno (cast listened)))

||| Connect to an IPv4 address and wait until the connection is made. Anything
||| else (a host name would need a blocking lookup, IPv6 is not supported) is
||| `EAFNOSUPPORT`. Like `accept`, the socket is handed over with `handoff`; a
||| connect that is given up while it is under way closes its socket.
export
connect : SocketAddress -> Port -> Task (Either Errno Sock)
connect addr@(IPv4Addr _ _ _ _) port = handoff start (either (\_ => pure ()) close)
  where
    -- A connection under way is done when the descriptor is writable; how it
    -- went is the pending error of the socket.
    finish : Sock -> IORef Bool -> Completion (Either Errno Sock) -> IO ()
    finish s settled done = do
      writeIORef settled True
      e <- primIO (prim__pendingError s.fd.rawfd)
      if e == 0 then done (Right s) else close s *> done (Left (MkErrno e))

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
    start env done = do
      opened <- socket AF_INET Stream 0
      case opened of
        Left e => noCancel <$ done (Left (MkErrno (cast e)))
        Right sock => do
          adopted <- adopt (cast sock.descriptor)
          case adopted of
            Left e => noCancel <$ done (Left e)
            Right s => do
              started <- Network.Socket.connect sock addr port
              if started == 0 then noCancel <$ done (Right s) else
                if elem (MkErrno (cast started)) [EINPROGRESS, EINTR] then waiting env s done
                else close s *> (noCancel <$ done (Left (MkErrno (cast started))))
connect _ _ = pure (Left EAFNOSUPPORT)

-- One attempt at a system call that answers -1 and sets `errno` on failure.
attempt : PrimIO Int -> IO (Either Errno Int)
attempt call = do
  n <- primIO call
  if n >= 0 then pure (Right n) else Left <$> errno

-- Repeat the call, waiting with `wait` when it would block.
retrying : (wait : Task EpollEvents) -> PrimIO Int -> Task (Either Errno Int)
retrying wait call = do
  r <- onReactor (attempt call)
  case r of
    Left e => if e == EAGAIN then wait *> retrying wait call
              else if e == EINTR then retrying wait call
              else pure r
    Right _ => pure r

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
      r <- attempt (prim__accept l.fd.rawfd)
      case r of
        Right n => adopt (cast n) >>= done
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
recv s buf off len = within buf off len (retrying (awaitReadable s.fd) (prim__recv s.fd.rawfd buf off len))

||| Write some of `buf[off .. off+len)`; the result is how many bytes went out
||| (`EINVAL` for an empty range or one outside the buffer).
export
send : Sock -> Buffer -> (off, len : Int) -> Task (Either Errno Int)
send s buf off len = within buf off len (retrying (awaitWritable s.fd) (prim__send s.fd.rawfd buf off len))

||| Write all of `buf[off .. off+len)`; nothing to do for an empty range.
export
sendAll : Sock -> Buffer -> (off, len : Int) -> Task (Either Errno ())
sendAll s buf off len =
  if len <= 0 then pure (Right ()) else do
    r <- send s buf off len
    case r of
      Left e => pure (Left e)
      Right n => sendAll s buf (off + n) (len - n)

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
