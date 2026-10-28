||| Offset+length socket IO straight into and out of a `Data.Buffer`,
||| for `Network.HTTP.Server`'s event loop.
|||
||| The standard `network` package only moves bytes through a `String`
||| (`send`/`recv` -- truncates at the first NUL, so unusable for binary)
||| or a `List Bits8` (`sendBytes`/`recvBytes` -- one cons cell per
||| byte). Neither works for an event-driven server shuffling binary
||| payloads through a reused accumulator buffer. `sendBuf`/`recvBuf`
||| here take a `Buffer` plus a byte offset and length, so the loop can
||| recv directly at its write cursor and send directly from its send
||| cursor with no intermediate copy -- backed by
||| `System.Posix.Socket` (no C shim). A failure is the `errno`, as
||| `Network.Socket`'s own `send`/`recv` give it.
|||
||| Same spirit as `System.Linux.Epoll`: the socket surface an
||| event-driven server needs that `network` doesn't expose in a usable
||| shape. Linux/POSIX, `--cg rc2` (the `%foreign` bindings are C-only).
module Network.RC2

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Data.Buffer
import Network.Socket
import Network.Socket.Data
import System.Posix.Errno
import System.Posix.FileDesc
import System.Posix.Socket as Posix

||| The descriptor of a `Network.Socket` socket, for `System.Posix.Socket`.
export
fromSocket : Socket -> Maybe FileDesc
fromSocket sock = mkFileDesc (cast sock.descriptor)

errnoCode : Errno -> SocketError
errnoCode (MkErrno e) = cast e

-- `Posix.send` / `Posix.recv` on the descriptor of the socket, with the
-- error as the `SocketError` that `network` uses.
viaFd : Socket -> (FileDesc -> IO (Either Errno Int)) -> IO (Either SocketError Int)
viaFd sock call = case fromSocket sock of
  Nothing => pure (Left (errnoCode EBADF))
  Just fd => mapFst errnoCode <$> call fd

||| The non-blocking "no data / can't send right now, try again on the
||| next epoll wakeup" case -- `EAGAIN` (which is `EWOULDBLOCK` on
||| Linux). Not a real error.
export
isWouldBlock : SocketError -> Bool
isWouldBlock e = e == EAGAIN

||| `send(sock, buf + off, len)`. `Right n` is the number of bytes
||| actually sent -- may be less than `len` on a non-blocking socket, in
||| which case the caller re-arms `EPOLLOUT` and resumes from `off + n`.
||| `Left e` is `errno`; check `isWouldBlock e` before treating it as
||| fatal.
export
sendBuf : HasIO io => Socket -> Buffer -> (off, len : Int) -> io (Either SocketError Int)
sendBuf sock buf off len = liftIO (viaFd sock (\fd => Posix.send fd buf off len MSG_NOSIGNAL))

||| `recv(sock, buf + off, len)`. `Right 0` means the peer closed the
||| connection; `Right n` (n > 0) is the byte count read into
||| `buf[off .. off+n)`. `Left e` is `errno` (see `isWouldBlock`).
export
recvBuf : HasIO io => Socket -> Buffer -> (off, len : Int) -> io (Either SocketError Int)
recvBuf sock buf off len = liftIO (viaFd sock (\fd => Posix.recv fd buf off len 0))
