||| The BSD socket calls on a `FileDesc`: `socket`, `bind`, `listen`, `accept`,
||| `connect`, `send` / `recv` into and out of a `Data.Buffer` (by offset and
||| length), `shutdown`, `getsockopt` / `setsockopt`, `getsockname` /
||| `getpeername`. Addresses are a `SockAddr` (IPv4, IPv6 or a Unix domain
||| path); a failure is `Left errno`. Names are not resolved here: `SockAddr`
||| holds numbers.
|||
||| `Network.Socket` of the `network` package is the portable surface; this is
||| the thin one over libc for `--cg rc2`, where a descriptor is shared with
||| `poll`, `epoll` and `fcntl`. `fromSocket` in `Network.RC2`
||| gives the descriptor of a `Network.Socket` socket.
module System.Posix.Socket

import Data.Buffer
import Data.Maybe
import Data.List
import Data.String.FFI
import System.FFI
import System.Posix.Errno
import System.Posix.FileDesc

%default covering

-------------------------------------------------------------------------------
-- Constants

||| An address family (`AF_*`).
public export
Family : Type
Family = Int32

||| A socket type (`SOCK_*`), possibly or-ed with `SOCK_NONBLOCK` / `SOCK_CLOEXEC`.
public export
SockType : Type
SockType = Int32

||| An or of `MSG_*` flags.
public export
MsgFlags : Type
MsgFlags = Int32

%inline %foreign "CExpr:(AF_UNSPEC),libc,sys/socket.h"
export AF_UNSPEC : Family
%inline %foreign "CExpr:(AF_UNIX),libc,sys/socket.h"
export AF_UNIX : Family
%inline %foreign "CExpr:(AF_INET),libc,sys/socket.h"
export AF_INET : Family
%inline %foreign "CExpr:(AF_INET6),libc,sys/socket.h"
export AF_INET6 : Family

%inline %foreign "CExpr:(SOCK_STREAM),libc,sys/socket.h"
export SOCK_STREAM : SockType
%inline %foreign "CExpr:(SOCK_DGRAM),libc,sys/socket.h"
export SOCK_DGRAM : SockType
||| Linux and BSD: the socket is made non-blocking.
%inline %foreign "CExpr:(SOCK_NONBLOCK),libc,sys/socket.h"
export SOCK_NONBLOCK : SockType
||| Linux and BSD: the socket is made close-on-exec.
%inline %foreign "CExpr:(SOCK_CLOEXEC),libc,sys/socket.h"
export SOCK_CLOEXEC : SockType

%inline %foreign "CExpr:(MSG_PEEK),libc,sys/socket.h"
export MSG_PEEK : MsgFlags
%inline %foreign "CExpr:(MSG_WAITALL),libc,sys/socket.h"
export MSG_WAITALL : MsgFlags
%inline %foreign "CExpr:(MSG_DONTWAIT),libc,sys/socket.h"
export MSG_DONTWAIT : MsgFlags
||| A peer that went away is an `EPIPE` result, not `SIGPIPE`.
%inline %foreign "CExpr:(MSG_NOSIGNAL),libc,sys/socket.h"
export MSG_NOSIGNAL : MsgFlags

||| A level of `getsockopt` / `setsockopt` (`SOL_SOCKET`, `IPPROTO_TCP`, ...).
public export
OptLevel : Type
OptLevel = Int32

||| An option name (`SO_*`, `TCP_NODELAY`, ...).
public export
OptName : Type
OptName = Int32

%inline %foreign "CExpr:(SOL_SOCKET),libc,sys/socket.h"
export SOL_SOCKET : OptLevel
%inline %foreign "CExpr:(IPPROTO_TCP),libc,netinet/in.h"
export IPPROTO_TCP : OptLevel
%inline %foreign "CExpr:(IPPROTO_IPV6),libc,netinet/in.h"
export IPPROTO_IPV6 : OptLevel

%inline %foreign "CExpr:(SO_REUSEADDR),libc,sys/socket.h"
export SO_REUSEADDR : OptName
%inline %foreign "CExpr:(SO_REUSEPORT),libc,sys/socket.h"
export SO_REUSEPORT : OptName
%inline %foreign "CExpr:(SO_KEEPALIVE),libc,sys/socket.h"
export SO_KEEPALIVE : OptName
%inline %foreign "CExpr:(SO_ERROR),libc,sys/socket.h"
export SO_ERROR : OptName
%inline %foreign "CExpr:(SO_RCVBUF),libc,sys/socket.h"
export SO_RCVBUF : OptName
%inline %foreign "CExpr:(SO_SNDBUF),libc,sys/socket.h"
export SO_SNDBUF : OptName
%inline %foreign "CExpr:(SO_BROADCAST),libc,sys/socket.h"
export SO_BROADCAST : OptName
%inline %foreign "CExpr:(TCP_NODELAY),libc,netinet/tcp.h;netinet/in.h"
export TCP_NODELAY : OptName
%inline %foreign "CExpr:(IPV6_V6ONLY),libc,netinet/in.h"
export IPV6_V6ONLY : OptName

-------------------------------------------------------------------------------
-- Addresses

||| A socket address.
public export
data SockAddr
  = ||| IPv4: the address as a number (`127.0.0.1` is `0x7f000001`) and the port.
    SockAddrIn Bits32 Bits16
  | ||| IPv6: the upper and the lower 64 bits of the address, and the port.
    SockAddrIn6 Bits64 Bits64 Bits16
  | ||| A Unix domain socket by path.
    SockAddrUn String

public export
Eq SockAddr where
  SockAddrIn a p == SockAddrIn b q = a == b && p == q
  SockAddrIn6 a b p == SockAddrIn6 c d q = a == c && b == d && p == q
  SockAddrUn a == SockAddrUn b = a == b
  _ == _ = False

public export
Show SockAddr where
  show (SockAddrIn a p) =
    let byte = \d => show ((a `div` d) `mod` 256)
     in byte 16777216 ++ "." ++ byte 65536 ++ "." ++ byte 256 ++ "." ++ byte 1 ++ ":" ++ show p
  show (SockAddrIn6 hi lo p) = "[" ++ groups hi ++ ":" ++ groups lo ++ "]:" ++ show p
    where
      nibble : Bits64 -> Bits64 -> Char
      nibble v d =
        let n = the Int (cast ((v `div` d) `mod` 16))
         in if n < 10 then chr (48 + n) else chr (87 + n)

      -- up to four hex digits, no leading zeros
      hex : Bits64 -> String
      hex v = case dropWhile (== '0') [nibble v 4096, nibble v 256, nibble v 16, nibble v 1] of
        [] => "0"
        cs => pack cs

      group : Bits64 -> Bits64 -> String
      group w d = hex ((w `div` d) `mod` 65536)

      groups : Bits64 -> String
      groups w = group w 281474976710656 ++ ":" ++ group w 4294967296 ++ ":" ++ group w 65536 ++ ":" ++ group w 1
  show (SockAddrUn path) = "unix:" ++ path

||| The loopback address of IPv4 on a port.
export
loopback : Bits16 -> SockAddr
loopback = SockAddrIn 0x7f000001

||| Every interface of IPv4, on a port.
export
anyAddr : Bits16 -> SockAddr
anyAddr = SockAddrIn 0

%inline %foreign "CExpr:(sizeof(struct sockaddr_storage)),libc,sys/socket.h"
prim__sizeofStorage : Int

%inline %foreign "CExpr:(*(socklen_t *)($1) = ($2)),libc,sys/socket.h"
prim__setSocklen : AnyPtr -> Bits32 -> PrimIO ()
%inline %foreign "CExpr:(*(socklen_t *)($1)),libc,sys/socket.h"
prim__getSocklen : AnyPtr -> PrimIO Bits32

%inline %foreign "CExpr:(((struct sockaddr *)($1))->sa_family),libc,sys/socket.h"
prim__saFamily : AnyPtr -> PrimIO Int32

%inline %foreign "CExpr:(memset($1, 0, sizeof(struct sockaddr_storage)), ((struct sockaddr_in *)($1))->sin_family = AF_INET, ((struct sockaddr_in *)($1))->sin_port = htons($3), ((struct sockaddr_in *)($1))->sin_addr.s_addr = htonl($2), (unsigned)sizeof(struct sockaddr_in)),libc,sys/socket.h;netinet/in.h;arpa/inet.h;string.h"
prim__fillIn : AnyPtr -> Bits32 -> Bits16 -> PrimIO Bits32
%inline %foreign "CExpr:(ntohs(((struct sockaddr_in *)($1))->sin_port)),libc,netinet/in.h;arpa/inet.h"
prim__inPort : AnyPtr -> PrimIO Bits16
%inline %foreign "CExpr:(ntohl(((struct sockaddr_in *)($1))->sin_addr.s_addr)),libc,netinet/in.h;arpa/inet.h"
prim__inAddr : AnyPtr -> PrimIO Bits32

%inline %foreign "CExpr:(({ memset($1, 0, sizeof(struct sockaddr_storage)); struct sockaddr_in6 *a = (struct sockaddr_in6 *)($1); a->sin6_family = AF_INET6; a->sin6_port = htons($4); for (int i = 0; i < 8; i++) { a->sin6_addr.s6_addr[i] = (unsigned char)(($2) >> (56 - 8 * i)); a->sin6_addr.s6_addr[8 + i] = (unsigned char)(($3) >> (56 - 8 * i)); } (unsigned)sizeof(struct sockaddr_in6); })),libc,sys/socket.h;netinet/in.h;arpa/inet.h;string.h"
prim__fillIn6 : AnyPtr -> Bits64 -> Bits64 -> Bits16 -> PrimIO Bits32
%inline %foreign "CExpr:(ntohs(((struct sockaddr_in6 *)($1))->sin6_port)),libc,netinet/in.h;arpa/inet.h"
prim__in6Port : AnyPtr -> PrimIO Bits16
%inline %foreign "CExpr:(({ uint64_t w = 0; for (int i = 0; i < 8; i++) w = (w << 8) | ((struct sockaddr_in6 *)($1))->sin6_addr.s6_addr[($2) + i]; w; })),libc,netinet/in.h;stdint.h"
prim__in6Word : AnyPtr -> Int -> PrimIO Bits64

%inline %foreign "CExpr:(({ memset($1, 0, sizeof(struct sockaddr_storage)); struct sockaddr_un *a = (struct sockaddr_un *)($1); a->sun_family = AF_UNIX; (strlen($2) >= sizeof(a->sun_path)) ? 0u : (strcpy(a->sun_path, $2), (unsigned)(offsetof(struct sockaddr_un, sun_path) + strlen(a->sun_path) + 1)); })),libc,sys/socket.h;sys/un.h;string.h;stddef.h"
prim__fillUn : AnyPtr -> String -> PrimIO Bits32
%inline %foreign "CExpr:((void *)((struct sockaddr_un *)($1))->sun_path),libc,sys/un.h"
prim__unPath : AnyPtr -> PrimIO AnyPtr

%inline %foreign "CExpr:memset($1, 0, $2),libc,string.h"
prim__memset : AnyPtr -> Int -> PrimIO ()

||| Run the call on the encoded address and its length, with the `errno` that it
||| left (read before the buffer is freed). `Nothing` when the address cannot be
||| encoded (a path too long for `sun_path`).
withSockAddr : SockAddr -> (AnyPtr -> Bits32 -> IO a) -> IO (Maybe (a, Errno))
withSockAddr addr call = do
  p <- malloc prim__sizeofStorage
  len <- case addr of
    SockAddrIn a port => primIO (prim__fillIn p a port)
    SockAddrIn6 hi lo port => primIO (prim__fillIn6 p hi lo port)
    SockAddrUn path => primIO (prim__fillUn p path)
  res <- if len == 0 then pure Nothing else do
    r <- call p len
    e <- errno
    pure (Just (r, e))
  free p
  pure res

-- A call that takes an address: the non-negative result, or `Left errno`.
viaAddr : SockAddr -> (AnyPtr -> Bits32 -> IO Int) -> IO (Either Errno Int)
viaAddr addr call = do
  res <- withSockAddr addr call
  pure $ case res of
    Nothing => Left ENAMETOOLONG
    Just (r, e) => if r >= 0 then Right r else Left e

-- The address that a call has written into `p`; `Nothing` for a family that is
-- not handled.
readSockAddr : AnyPtr -> IO (Maybe SockAddr)
readSockAddr p = do
  family <- primIO (prim__saFamily p)
  if family == AF_INET then readIn p
    else if family == AF_INET6 then readIn6 p
    else if family == AF_UNIX then readUn p
    else pure Nothing
  where
    readIn : AnyPtr -> IO (Maybe SockAddr)
    readIn p = do
      a <- primIO (prim__inAddr p)
      port <- primIO (prim__inPort p)
      pure (Just (SockAddrIn a port))

    readIn6 : AnyPtr -> IO (Maybe SockAddr)
    readIn6 p = do
      hi <- primIO (prim__in6Word p 0)
      lo <- primIO (prim__in6Word p 8)
      port <- primIO (prim__in6Port p)
      pure (Just (SockAddrIn6 hi lo port))

    readUn : AnyPtr -> IO (Maybe SockAddr)
    readUn p = do
      path <- primIO (prim__unPath p) >>= ptrToString
      pure (Just (SockAddrUn (fromMaybe "" path)))

||| Run the call on room for an address and its length (both to be written by
||| the call) and read the address back, with the `errno` that the call left.
||| The address is read only when the call succeeded and wrote more than the
||| family (an unnamed Unix domain peer is `Nothing`).
withAddrOut : (AnyPtr -> AnyPtr -> IO Int) -> IO (Int, Maybe SockAddr, Errno)
withAddrOut call = do
  let size = prim__sizeofStorage
  p <- malloc size
  len <- malloc 4   -- a socklen_t
  primIO (prim__memset p size)
  primIO (prim__setSocklen len (cast size))
  r <- call p len
  e <- errno
  written <- primIO (prim__getSocklen len)
  addr <- if r >= 0 && written > 2 then readSockAddr p else pure Nothing
  free len
  free p
  pure (r, addr, e)

-------------------------------------------------------------------------------
-- Calls

%inline %foreign "CExpr:(socket($1, $2, $3)),libc,sys/socket.h"
prim__socket : Family -> SockType -> Int32 -> PrimIO Int32
%inline %foreign "CExpr:(socketpair($1, $2, $3, (int *)($4))),libc,sys/socket.h"
prim__socketpair : Family -> SockType -> Int32 -> AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(bind($1, (const struct sockaddr *)($2), $3)),libc,sys/socket.h"
prim__bind : Int32 -> AnyPtr -> Bits32 -> PrimIO Int32
%inline %foreign "CExpr:(connect($1, (const struct sockaddr *)($2), $3)),libc,sys/socket.h"
prim__connect : Int32 -> AnyPtr -> Bits32 -> PrimIO Int32
%inline %foreign "CExpr:(listen($1, $2)),libc,sys/socket.h"
prim__listen : Int32 -> Int32 -> PrimIO Int32
%inline %foreign "CExpr:(accept($1, (struct sockaddr *)($2), (socklen_t *)($3))),libc,sys/socket.h"
prim__accept : Int32 -> AnyPtr -> AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(accept($1, NULL, NULL)),libc,sys/socket.h"
prim__acceptAny : Int32 -> PrimIO Int32
%inline %foreign "CExpr:(shutdown($1, $2)),libc,sys/socket.h"
prim__shutdown : Int32 -> Int32 -> PrimIO Int32

%inline %foreign "CExpr:((int)send($1, (char *)($2) + ($3), (size_t)($4), $5)),libc,sys/socket.h"
prim__send : Int32 -> Buffer -> Int -> Int -> MsgFlags -> PrimIO Int
%inline %foreign "CExpr:((int)recv($1, (char *)($2) + ($3), (size_t)($4), $5)),libc,sys/socket.h"
prim__recv : Int32 -> Buffer -> Int -> Int -> MsgFlags -> PrimIO Int
%inline %foreign "CExpr:((int)sendto($1, (char *)($2) + ($3), (size_t)($4), $5, (const struct sockaddr *)($6), $7)),libc,sys/socket.h"
prim__sendto : Int32 -> Buffer -> Int -> Int -> MsgFlags -> AnyPtr -> Bits32 -> PrimIO Int
%inline %foreign "CExpr:((int)recvfrom($1, (char *)($2) + ($3), (size_t)($4), $5, (struct sockaddr *)($6), (socklen_t *)($7))),libc,sys/socket.h"
prim__recvfrom : Int32 -> Buffer -> Int -> Int -> MsgFlags -> AnyPtr -> AnyPtr -> PrimIO Int

%inline %foreign "CExpr:(({ int v = ($4); setsockopt($1, $2, $3, &v, sizeof v); })),libc,sys/socket.h"
prim__setsockoptInt : Int32 -> OptLevel -> OptName -> Int32 -> PrimIO Int32
%inline %foreign "CExpr:(({ socklen_t l = sizeof(int); getsockopt($1, $2, $3, (int *)($4), &l); })),libc,sys/socket.h"
prim__getsockoptInt : Int32 -> OptLevel -> OptName -> AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(((int *)($1))[$2]),libc"
prim__peekInt : AnyPtr -> Int -> PrimIO Int32
%inline %foreign "CExpr:(getsockname($1, (struct sockaddr *)($2), (socklen_t *)($3))),libc,sys/socket.h"
prim__getsockname : Int32 -> AnyPtr -> AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(getpeername($1, (struct sockaddr *)($2), (socklen_t *)($3))),libc,sys/socket.h"
prim__getpeername : Int32 -> AnyPtr -> AnyPtr -> PrimIO Int32

-- `Right n` for a non-negative count, otherwise `Left errno`.
count : Int -> IO (Either Errno Int)
count n = if n >= 0 then pure (Right n) else Left <$> errno

||| A new socket.
export
socket : Family -> SockType -> (protocol : Int32) -> IO (Either Errno FileDesc)
socket family type protocol = primIO (prim__socket family type protocol) >>= primFdToFileDesc

||| Two connected sockets (`AF_UNIX` is the family that every system has).
export
socketpair : Family -> SockType -> (protocol : Int32) -> IO (Either Errno (FileDesc, FileDesc))
socketpair family type protocol = do
  p <- malloc 8
  rc <- primIO (prim__socketpair family type protocol p)
  res <- if rc < 0 then Left <$> errno else do
    a <- primIO (prim__peekInt p 0)
    b <- primIO (prim__peekInt p 1)
    pure (case (mkFileDesc a, mkFileDesc b) of
            (Just x, Just y) => Right (x, y)
            _ => Left EBADF)
  free p
  pure res

||| Give the socket a local address.
export
bind : FileDesc -> SockAddr -> IO (Either Errno ())
bind fd addr = map (const ()) <$> viaAddr addr (\p, len => cast <$> primIO (prim__bind fd.rawfd p len))

||| Connect to the address. On a non-blocking socket `EINPROGRESS` means the
||| connection is under way: wait for the descriptor to be writable, then read
||| `socketError`.
export
connect : FileDesc -> SockAddr -> IO (Either Errno ())
connect fd addr = map (const ()) <$> viaAddr addr (\p, len => cast <$> primIO (prim__connect fd.rawfd p len))

||| Mark the socket as one that takes connections, with room for `backlog`
||| waiting ones.
export
listen : FileDesc -> (backlog : Int32) -> IO (Either Errno ())
listen fd backlog = primIO (prim__listen fd.rawfd backlog) >>= checkUnit

||| The next connection and the address of the other end (`Nothing` when it is
||| of a family that `SockAddr` does not hold, or unnamed). The new socket is
||| blocking and not close-on-exec, whatever the listening one is; set what is
||| needed on it.
export
accept : FileDesc -> IO (Either Errno (FileDesc, Maybe SockAddr))
accept fd = do
  (n, addr, e) <- withAddrOut (\p, len => cast <$> primIO (prim__accept fd.rawfd p len))
  pure $ case mkFileDesc (cast n) of
    Just conn => if n >= 0 then Right (conn, addr) else Left e
    Nothing => Left e

||| `accept` without asking for the address.
export
acceptFd : FileDesc -> IO (Either Errno FileDesc)
acceptFd fd = primIO (prim__acceptAny fd.rawfd) >>= primFdToFileDesc

||| What `shutdown` ends.
public export
data ShutdownHow = ShutRead | ShutWrite | ShutReadWrite

%inline %foreign "CExpr:(SHUT_RD),libc,sys/socket.h"
prim__SHUT_RD : Int32
%inline %foreign "CExpr:(SHUT_WR),libc,sys/socket.h"
prim__SHUT_WR : Int32
%inline %foreign "CExpr:(SHUT_RDWR),libc,sys/socket.h"
prim__SHUT_RDWR : Int32

||| Stop one or both directions; `ShutWrite` tells the peer that nothing more
||| comes while what it sends can still be read.
export
shutdown : FileDesc -> ShutdownHow -> IO (Either Errno ())
shutdown fd how = primIO (prim__shutdown fd.rawfd (code how)) >>= checkUnit
  where
    code : ShutdownHow -> Int32
    code ShutRead = prim__SHUT_RD
    code ShutWrite = prim__SHUT_WR
    code ShutReadWrite = prim__SHUT_RDWR

||| `send` of `buf[off .. off+len)`: the number of bytes taken, which may be
||| less than `len`. The range is the caller's to keep inside the buffer.
export
send : FileDesc -> Buffer -> (off, len : Int) -> MsgFlags -> IO (Either Errno Int)
send fd buf off len flags =
  if off < 0 || len < 0 then pure (Left EINVAL)
  else primIO (prim__send fd.rawfd buf off len flags) >>= count

||| `recv` into `buf[off .. off+len)`: the number of bytes read, 0 when the peer
||| has closed (for a stream). The range is the caller's to keep inside the buffer.
export
recv : FileDesc -> Buffer -> (off, len : Int) -> MsgFlags -> IO (Either Errno Int)
recv fd buf off len flags =
  if off < 0 || len < 0 then pure (Left EINVAL)
  else primIO (prim__recv fd.rawfd buf off len flags) >>= count

||| `sendto` of `buf[off .. off+len)` to the address.
export
sendTo : FileDesc -> Buffer -> (off, len : Int) -> MsgFlags -> SockAddr -> IO (Either Errno Int)
sendTo fd buf off len flags addr =
  if off < 0 || len < 0 then pure (Left EINVAL)
  else viaAddr addr (\p, alen => primIO (prim__sendto fd.rawfd buf off len flags p alen))

||| `recvfrom` into `buf[off .. off+len)`: the number of bytes and the sender.
export
recvFrom : FileDesc -> Buffer -> (off, len : Int) -> MsgFlags -> IO (Either Errno (Int, Maybe SockAddr))
recvFrom fd buf off len flags =
  if off < 0 || len < 0 then pure (Left EINVAL) else do
    (n, addr, e) <- withAddrOut (\p, alen => primIO (prim__recvfrom fd.rawfd buf off len flags p alen))
    pure (if n >= 0 then Right (n, addr) else Left e)

||| Set an option whose value is an `int` (`SO_REUSEADDR`, `TCP_NODELAY`, ...).
export
setSockOptInt : FileDesc -> OptLevel -> OptName -> Int32 -> IO (Either Errno ())
setSockOptInt fd level name value = primIO (prim__setsockoptInt fd.rawfd level name value) >>= checkUnit

||| The value of an option that is an `int`.
export
getSockOptInt : FileDesc -> OptLevel -> OptName -> IO (Either Errno Int32)
getSockOptInt fd level name = do
  p <- malloc 4
  rc <- primIO (prim__getsockoptInt fd.rawfd level name p)
  res <- if rc < 0 then Left <$> errno else Right <$> primIO (prim__peekInt p 0)
  free p
  pure res

||| The error that a non-blocking `connect` ended with (`SO_ERROR`): 0 when it
||| went well. Reading it clears it.
export
socketError : FileDesc -> IO (Either Errno Errno)
socketError fd = map MkErrno <$> getSockOptInt fd SOL_SOCKET SO_ERROR

||| The local address of the socket.
export
getSockName : FileDesc -> IO (Either Errno (Maybe SockAddr))
getSockName fd = do
  (rc, addr, e) <- withAddrOut (\p, len => cast <$> primIO (prim__getsockname fd.rawfd p len))
  pure (if rc == 0 then Right addr else Left e)

||| The address of the other end of a connected socket.
export
getPeerName : FileDesc -> IO (Either Errno (Maybe SockAddr))
getPeerName fd = do
  (rc, addr, e) <- withAddrOut (\p, len => cast <$> primIO (prim__getpeername fd.rawfd p len))
  pure (if rc == 0 then Right addr else Left e)

%inline %foreign "CExpr:((void *)inet_ntop(AF_INET, &((struct sockaddr_in *)($1))->sin_addr, (char *)($2), $3)),libc,arpa/inet.h;netinet/in.h"
prim__ntopIn : AnyPtr -> AnyPtr -> Bits32 -> PrimIO AnyPtr
%inline %foreign "CExpr:((void *)inet_ntop(AF_INET6, &((struct sockaddr_in6 *)($1))->sin6_addr, (char *)($2), $3)),libc,arpa/inet.h;netinet/in.h"
prim__ntopIn6 : AnyPtr -> AnyPtr -> Bits32 -> PrimIO AnyPtr

||| The address without the port, as text (`192.0.2.1`, `2001:db8::1`);
||| `Nothing` for a Unix domain address.
export
addressText : SockAddr -> IO (Maybe String)
addressText (SockAddrUn _) = pure Nothing
addressText addr = do
  buf <- malloc 64
  r <- withSockAddr addr (\p, _ => case addr of
         SockAddrIn6 _ _ _ => primIO (prim__ntopIn6 p buf 64)
         _ => primIO (prim__ntopIn p buf 64))
  s <- case r of
         Just (found, _) => if prim__nullAnyPtr found /= 0 then pure Nothing else ptrToString buf
         Nothing => pure Nothing
  free buf
  pure s

-------------------------------------------------------------------------------
-- Name resolution

||| `AI_*` flags of `getAddrInfo`.
public export
AddrInfoFlags : Type
AddrInfoFlags = Int32

%inline %foreign "CExpr:(AI_PASSIVE),libc,netdb.h"
export AI_PASSIVE : AddrInfoFlags
%inline %foreign "CExpr:(AI_NUMERICHOST),libc,netdb.h"
export AI_NUMERICHOST : AddrInfoFlags
||| The service is a decimal port number, so no service database is read.
%inline %foreign "CExpr:(AI_NUMERICSERV),libc,netdb.h"
export AI_NUMERICSERV : AddrInfoFlags

data RawAddrInfo : Type where [external]

%inline %foreign "CExpr:(sizeof(void *)),libc"
prim__sizeofPtr : Int
%inline %foreign "CExpr:(*(void **)($1)),libc"
prim__readPtr : AnyPtr -> PrimIO AnyPtr

%inline %foreign "CExpr:(sizeof(struct addrinfo)),libc,netdb.h"
prim__sizeofAddrInfo : Int
%inline %foreign "CExpr:(((struct addrinfo *)($1))->ai_family = ($2), ((struct addrinfo *)($1))->ai_socktype = ($3), ((struct addrinfo *)($1))->ai_flags = ($4), 0),libc,netdb.h;sys/socket.h"
prim__setHints : AnyPtr -> Family -> SockType -> AddrInfoFlags -> PrimIO Int32
%inline %foreign "CExpr:(getaddrinfo($1, $2, (const struct addrinfo *)($3), (struct addrinfo **)($4))),libc,netdb.h;sys/socket.h"
prim__getaddrinfo : String -> String -> AnyPtr -> AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(((struct addrinfo *)($1))->ai_addr),libc,netdb.h"
prim__aiAddr : GCPtr RawAddrInfo -> PrimIO AnyPtr
%inline %foreign "CExpr:(((struct addrinfo *)($1))->ai_addrlen),libc,netdb.h"
prim__aiAddrLen : GCPtr RawAddrInfo -> PrimIO Bits32
%inline %foreign "CExpr:freeaddrinfo($1),libc,netdb.h"
prim__freeAddrInfo : Ptr RawAddrInfo -> PrimIO ()
%inline %foreign "CExpr:(EAI_SYSTEM),libc,netdb.h"
prim__EAI_SYSTEM : Int32

||| The result of `getAddrInfo`: a list of addresses that `freeaddrinfo`s itself
||| when nothing refers to it any more. Whoever hands the address on to the
||| kernel to read later (`io_uring`) has to keep this value alive until then.
export
data AddrInfo = MkAddrInfo (GCPtr RawAddrInfo)

||| `getaddrinfo` of a host name or numeric address and a service (a port
||| number as text, with `AI_NUMERICSERV`, or a service name). `Left` is the
||| `EAI_*` code. It may ask a name server, so it blocks.
export
getAddrInfo : (host, service : String) -> Family -> SockType -> AddrInfoFlags
           -> IO (Either Int32 AddrInfo)
getAddrInfo host service family type flags = do
  hints <- malloc prim__sizeofAddrInfo
  slot <- malloc prim__sizeofPtr
  if prim__nullAnyPtr hints /= 0 || prim__nullAnyPtr slot /= 0
     then free hints *> free slot *> pure (Left prim__EAI_SYSTEM)
     else do
       primIO (prim__memset hints prim__sizeofAddrInfo)
       _ <- primIO (prim__setHints hints family type flags)
       rc <- primIO (prim__getaddrinfo host service hints slot)
       found <- primIO (prim__readPtr slot)
       free hints
       free slot
       if rc == 0 && prim__nullAnyPtr found == 0
          then Right . MkAddrInfo <$> onCollect (prim__castPtr found) (primIO . prim__freeAddrInfo)
          else pure (Left (if rc == 0 then prim__EAI_SYSTEM else rc))

||| The first address of the result, in `SockAddr` form (`Nothing` for a family
||| that it does not hold).
export
addrInfoAddress : AddrInfo -> IO (Maybe SockAddr)
addrInfoAddress (MkAddrInfo info) = primIO (prim__aiAddr info) >>= readSockAddr

||| The first address of the result as the `struct sockaddr *` that C calls
||| take, and its length. The pointer is valid while the `AddrInfo` is alive.
export
addrInfoRaw : AddrInfo -> IO (AnyPtr, Bits32)
addrInfoRaw (MkAddrInfo info) = do
  p <- primIO (prim__aiAddr info)
  len <- primIO (prim__aiAddrLen info)
  pure (p, len)
