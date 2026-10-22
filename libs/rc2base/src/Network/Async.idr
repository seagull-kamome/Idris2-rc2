||| Sockets for `Control.Task`: `accept`, `recv` and `send` that wait for the
||| descriptor on the scheduler's epoll instead of blocking a thread. A `Sock`
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

||| Run the task and close the socket when it ends or is given up (its scope
||| is cancelled, a `race` lost). The close on cancellation is what stops a
||| server from leaking the connections it was serving.
export
withSock : Sock -> Task a -> Task a
withSock s body = do
  guard <- onReactor (newIORef (pure ()))
  spawn (Async (\_, done => writeIORef guard (done ()) *> pure (MkCancel (close s))))
  r <- body
  onReactor (close s *> join (readIORef guard))
  pure r

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

-- One attempt at a system call that answers -1 and sets `errno` on failure.
attempt : PrimIO Int -> IO (Either Errno Int)
attempt call = do
  n <- primIO call
  if n >= 0 then pure (Right n) else Left <$> errno

-- Repeat the call, waiting with `wait` when it would block.
retrying : (wait : Task EpollEvents) -> PrimIO Int -> Task (Either Errno Int)
retrying wait call = do
  r <- liftIO (attempt call)
  case r of
    Left e => if e == EAGAIN then wait *> retrying wait call
              else if e == EINTR then retrying wait call
              else pure r
    Right _ => pure r

||| The next connection. Waits until one arrives.
export
accept : Sock -> Task (Either Errno Sock)
accept l = do
  Right n <- retrying (awaitReadable l.fd) (prim__accept l.fd.rawfd)
    | Left e => pure (Left e)
  liftIO (adopt (cast n))

||| Read up to `len` bytes into `buf[off ..]`. Waits until there is something to
||| read. `Right 0` means the peer closed the connection.
export
recv : Sock -> Buffer -> (off, len : Int) -> Task (Either Errno Int)
recv s buf off len = retrying (awaitReadable s.fd) (prim__recv s.fd.rawfd buf off len)

||| Write some of `buf[off .. off+len)`; the result is how many bytes went out.
export
send : Sock -> Buffer -> (off, len : Int) -> Task (Either Errno Int)
send s buf off len = retrying (awaitWritable s.fd) (prim__send s.fd.rawfd buf off len)

||| Write all of `buf[off .. off+len)`.
export
sendAll : Sock -> Buffer -> (off, len : Int) -> Task (Either Errno ())
sendAll s buf off len =
  if len <= 0 then pure (Right ()) else do
    r <- send s buf off len
    case r of
      Left e => pure (Left e)
      Right n => sendAll s buf (off + n) (len - n)
