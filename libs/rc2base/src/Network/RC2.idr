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
||| cursor with no intermediate copy -- backed by a tiny C shim
||| (`support/c/net_util.c`) over plain `send`/`recv`. `errno` on
||| failure is read with `Network.Socket.Data.getErrno`, the same
||| accessor `Network.Socket`'s own `send`/`recv` use.
|||
||| Same spirit as `System.Net.Epoll`: the socket surface an
||| event-driven server needs that `network` doesn't expose in a usable
||| shape. Linux/POSIX, `--cg rc2` (the `%foreign` bindings are C-only).
module Network.RC2

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Data.Buffer
import Network.Socket
import Network.Socket.Data

-------------------------------------------------------------------------------
-- Raw FFI (support/c/net_util.c)
-------------------------------------------------------------------------------

-- `Buffer` is passed under rc2's generic "C:" ABI, i.e. as the raw byte
-- pointer past the size header -- `net_util.c` then does `data + off`.
%foreign "C:idris2rc2_buf_send, libidris2rc2base, net_util.h"
prim__bufSend : Int -> Buffer -> Int -> Int -> PrimIO Int

%foreign "C:idris2rc2_buf_recv, libidris2rc2base, net_util.h"
prim__bufRecv : Int -> Buffer -> Int -> Int -> PrimIO Int

-------------------------------------------------------------------------------
-- Wrappers
-------------------------------------------------------------------------------

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
sendBuf sock buf off len = do
  n <- primIO (prim__bufSend sock.descriptor buf off len)
  if n < 0 then Left <$> getErrno else pure (Right n)

||| `recv(sock, buf + off, len)`. `Right 0` means the peer closed the
||| connection; `Right n` (n > 0) is the byte count read into
||| `buf[off .. off+n)`. `Left e` is `errno` (see `isWouldBlock`).
export
recvBuf : HasIO io => Socket -> Buffer -> (off, len : Int) -> io (Either SocketError Int)
recvBuf sock buf off len = do
  n <- primIO (prim__bufRecv sock.descriptor buf off len)
  if n < 0 then Left <$> getErrno else pure (Right n)
