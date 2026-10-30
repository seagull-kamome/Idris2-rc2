||| Offset+length socket IO straight into and out of a `Data.Buffer`,
||| for `Network.Async` and the event loop of `Network.HTTP.Server` (`web`).
|||
||| The standard `network` package only moves bytes through a `String`
||| (`send`/`recv` -- truncates at the first NUL, so unusable for binary)
||| or a `List Bits8` (`sendBytes`/`recvBytes` -- one cons cell per
||| byte). Neither works for an event-driven server shuffling binary
||| payloads through a reused accumulator buffer. `sendBuf`/`recvBuf`
||| here take a `Buffer` plus a byte offset and length, so the loop can
||| recv directly at its write cursor and send directly from its send
||| cursor with no intermediate copy -- backed by
||| `System.Posix.Socket` (no C shim). A failure is the `errno`.
|||
||| Same spirit as `System.Linux.Epoll`: the socket surface an
||| event-driven server needs that `network` doesn't expose in a usable
||| shape. Linux/POSIX, `--cg rc2` (the `%foreign` bindings are C-only).
module Network.RC2

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Data.Buffer
import public System.Posix.Errno
import System.Posix.FileDesc
import System.Posix.Socket as Posix

%default covering

||| True when the call would block on a non-blocking socket (`EAGAIN`).
export
isWouldBlock : Errno -> Bool
isWouldBlock e = e == EAGAIN

||| Send `buf[off .. off+len)` (`MSG_NOSIGNAL`). `Right n` is the number of
||| bytes the kernel took; `Left e` is `errno`, check `isWouldBlock e` before
||| treating it as a failure on a non-blocking socket.
export
sendBuf : HasIO io => FileDesc -> Buffer -> (off, len : Int) -> io (Either Errno Int)
sendBuf fd buf off len = liftIO (Posix.send fd buf off len MSG_NOSIGNAL)

||| Receive up to `len` bytes into `buf[off ..)`. `Right 0` is end of stream,
||| `Right n` the bytes now in `buf[off .. off+n)`. `Left e` is `errno` (see
||| `isWouldBlock`).
export
recvBuf : HasIO io => FileDesc -> Buffer -> (off, len : Int) -> io (Either Errno Int)
recvBuf fd buf off len = liftIO (Posix.recv fd buf off len 0)

||| Send a `String` as its UTF-8 bytes, all of it. Blocks on a blocking socket.
export
sendString : HasIO io => FileDesc -> String -> io (Either Errno ())
sendString fd str = liftIO (start (stringByteLength str))
  where
    go : Buffer -> Int -> Int -> IO (Either Errno ())
    go buf size sent =
      if sent >= size then pure (Right ())
      else case !(Posix.send fd buf sent (size - sent) MSG_NOSIGNAL) of
             Left e => pure (Left e)
             Right n => go buf size (sent + n)

    start : Int -> IO (Either Errno ())
    start size = do
      Just buf <- newBuffer size
        | Nothing => pure (Left ENOMEM)
      setString buf 0 str
      go buf size 0

||| Receive at most `max` bytes and read them as a `String`; `""` is end of
||| stream. Blocks on a blocking socket.
export
recvString : HasIO io => FileDesc -> (max : Int) -> io (Either Errno String)
recvString fd max = liftIO $ do
  Just buf <- newBuffer max
    | Nothing => pure (Left ENOMEM)
  case !(Posix.recv fd buf 0 max 0) of
    Left e => pure (Left e)
    Right n => Right <$> getString buf 0 n
