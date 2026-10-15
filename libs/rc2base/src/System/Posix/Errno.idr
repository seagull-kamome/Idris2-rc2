module System.Posix.Errno

import Data.String.RC2
import Data.String.FFI
import System.FFI

-------------------------------------------------------------------------------
--

||| Represents a POSIX errno value.
public export
data Errno = MkErrno Int32

||| Equality comparison for `Errno` values.
public export
Eq Errno where
  (==) (MkErrno a) (MkErrno b) = a == b

||| Ordering for `Errno` values.
public export
Ord Errno where
  compare (MkErrno a) (MkErrno b) = compare a b

||| String rendering for `Errno` values.
public export
Show Errno where
  show (MkErrno code) = "Errno:" ++ show code

-------------------------------------------------------------------------------
--

%inline %foreign "CExpr:(errno),libc,errno.h"
prim__errno : PrimIO Int32

||| Return the current value of `errno`.
public export errno : IO Errno
errno = MkErrno <$> primIO prim__errno



||| `Right ()` for the return value 0 of a call that reports failure by a
||| nonzero (usually -1) value, otherwise `Left errno`.
public export
checkUnit : Int32 -> IO (Either Errno ())
checkUnit r = if r == 0 then pure (Right ()) else map Left errno

||| `Right r` for a non-negative return value, otherwise `Left errno`.
public export
checkNonNeg : Int32 -> IO (Either Errno Int32)
checkNonNeg r = if r >= 0 then pure (Right r) else map Left errno

-------------------------------------------------------------------------------
--

%inline %foreign "CExpr:(strerror_r($1, $2, $3)),libc,string.h"
prim__strerror : Int32 -> AnyPtr -> Bits64 -> PrimIO Int32
||| Return a human-readable description of the given errno code.
public export strerror : Int32 -> IO String
strerror code = do
  buf <- malloc 1024
  r <- primIO $ prim__strerror code buf 1024
  if r == 0
    then do
      Just r <- ptrToStringFree buf
        |  _ => pure $ "No enough memory, cannot allocate buffer for strerror for " ++ show code
      pure r
    else do
      free buf
      pure $ "Unknown error " ++ show code


%inline %foreign "CExpr:(perror($1)),libc,stdio.h"
prim__perror : String -> PrimIO ()
||| Print a message and the current system error string to standard error.
%inline public export perror : String -> IO ()
perror s = primIO $ prim__perror s


-- cannot be implemented error, error_at_line due to varargs.


-------------------------------------------------------------------------------
--

%inline %foreign "CExpr:(E2BIG),libc,errno.h"
prim__E2BIG : Int32
||| The `E2BIG` errno value.
%inline public export
E2BIG : Errno
E2BIG = MkErrno prim__E2BIG

%inline %foreign "CExpr:(EACCES),libc,errno.h"
prim__EACCES : Int32
||| The `EACCES` errno value.
%inline public export
EACCES : Errno
EACCES = MkErrno prim__EACCES

%inline %foreign "CExpr:(EADDRINUSE),libc,errno.h"
prim__EADDRINUSE : Int32
||| The `EADDRINUSE` errno value.
%inline public export
EADDRINUSE : Errno
EADDRINUSE = MkErrno prim__EADDRINUSE

%inline %foreign "CExpr:(EADDRNOTAVAIL),libc,errno.h"
prim__EADDRNOTAVAIL : Int32
||| The `EADDRNOTAVAIL` errno value.
%inline public export
EADDRNOTAVAIL : Errno
EADDRNOTAVAIL = MkErrno prim__EADDRNOTAVAIL

%inline %foreign "CExpr:(EAFNOSUPPORT),libc,errno.h"
prim__EAFNOSUPPORT : Int32
||| The `EAFNOSUPPORT` errno value.
%inline public export
EAFNOSUPPORT : Errno
EAFNOSUPPORT = MkErrno prim__EAFNOSUPPORT

%inline %foreign "CExpr:(EAGAIN),libc,errno.h"
prim__EAGAIN : Int32
||| The `EAGAIN` errno value.
%inline public export
EAGAIN : Errno
EAGAIN = MkErrno prim__EAGAIN

%inline %foreign "CExpr:(EALREADY),libc,errno.h"
prim__EALREADY : Int32
||| The `EALREADY` errno value.
%inline public export
EALREADY : Errno
EALREADY = MkErrno prim__EALREADY

%inline %foreign "CExpr:(EBADF),libc,errno.h"
prim__EBADF : Int32
||| The `EBADF` errno value.
%inline public export
EBADF : Errno
EBADF = MkErrno prim__EBADF

%inline %foreign "CExpr:(EBADFD),libc,errno.h"
prim__EBADFD : Int32
||| The `EBADFD` errno value.
|||
||| Linux only, not in POSIX; see `errno(3)`.
%inline public export
EBADFD : Errno
EBADFD = MkErrno prim__EBADFD

%inline %foreign "CExpr:(EBADMSG),libc,errno.h"
prim__EBADMSG : Int32
||| The `EBADMSG` errno value.
%inline public export
EBADMSG : Errno
EBADMSG = MkErrno prim__EBADMSG

%inline %foreign "CExpr:(EBADR),libc,errno.h"
prim__EBADR : Int32
||| The `EBADR` errno value.
|||
||| Linux only, not in POSIX; see `errno(3)`.
%inline public export
EBADR : Errno
EBADR = MkErrno prim__EBADR

%inline %foreign "CExpr:(EBADRQC),libc,errno.h"
prim__EBADRQC : Int32
||| The `EBADRQC` errno value.
|||
||| Linux only, not in POSIX; see `errno(3)`.
%inline public export
EBADRQC : Errno
EBADRQC = MkErrno prim__EBADRQC

%inline %foreign "CExpr:(EBADSLT),libc,errno.h"
prim__EBADSLT : Int32
||| The `EBADSLT` errno value.
|||
||| Linux only, not in POSIX; see `errno(3)`.
%inline public export
EBADSLT : Errno
EBADSLT = MkErrno prim__EBADSLT

%inline %foreign "CExpr:(EBUSY),libc,errno.h"
prim__EBUSY : Int32
||| The `EBUSY` errno value.
%inline public export
EBUSY : Errno
EBUSY = MkErrno prim__EBUSY

%inline %foreign "CExpr:(ECANCELED),libc,errno.h"
prim__ECANCELED : Int32
||| The `ECANCELED` errno value.
%inline public export
ECANCELED : Errno
ECANCELED = MkErrno prim__ECANCELED

%inline %foreign "CExpr:(ECHILD),libc,errno.h"
prim__ECHILD : Int32
||| The `ECHILD` errno value.
%inline public export
ECHILD : Errno
ECHILD = MkErrno prim__ECHILD

%inline %foreign "CExpr:(ECHRNG),libc,errno.h"
prim__ECHRNG : Int32
||| The `ECHRNG` errno value.
|||
||| Linux only, not in POSIX; see `errno(3)`.
%inline public export
ECHRNG : Errno
ECHRNG = MkErrno prim__ECHRNG

%inline %foreign "CExpr:(ECOMM),libc,errno.h"
prim__ECOMM : Int32
||| The `ECOMM` errno value.
|||
||| Linux only, not in POSIX; see `errno(3)`.
%inline public export
ECOMM : Errno
ECOMM = MkErrno prim__ECOMM

%inline %foreign "CExpr:(ECONNABORTED),libc,errno.h"
prim__ECONNABORTED : Int32
||| The `ECONNABORTED` errno value.
%inline public export
ECONNABORTED : Errno
ECONNABORTED = MkErrno prim__ECONNABORTED

%inline %foreign "CExpr:(ECONNREFUSED),libc,errno.h"
prim__ECONNREFUSED : Int32
||| The `ECONNREFUSED` errno value.
%inline public export
ECONNREFUSED : Errno
ECONNREFUSED = MkErrno prim__ECONNREFUSED

%inline %foreign "CExpr:(ECONNRESET),libc,errno.h"
prim__ECONNRESET : Int32
||| The `ECONNRESET` errno value.
%inline public export
ECONNRESET : Errno
ECONNRESET = MkErrno prim__ECONNRESET

%inline %foreign "CExpr:(EDEADLK),libc,errno.h"
prim__EDEADLK : Int32
||| The `EDEADLK` errno value.
%inline public export
EDEADLK : Errno
EDEADLK = MkErrno prim__EDEADLK

%inline %foreign "CExpr:(EDEADLOCK),libc,errno.h"
prim__EDEADLOCK : Int32
||| The `EDEADLOCK` errno value.
|||
||| Linux only, not in POSIX; see `errno(3)`.
%inline public export
EDEADLOCK : Errno
EDEADLOCK = EDEADLK

%inline %foreign "CExpr:(EDESTADDRREQ),libc,errno.h"
prim__EDESTADDRREQ : Int32
||| The `EDESTADDRREQ` errno value.
%inline public export
EDESTADDRREQ : Errno
EDESTADDRREQ = MkErrno prim__EDESTADDRREQ

%inline %foreign "CExpr:(EDOM),libc,errno.h"
prim__EDOM : Int32
||| The `EDOM` errno value.
%inline public export
EDOM : Errno
EDOM = MkErrno prim__EDOM

%inline %foreign "CExpr:(EDQUOT),libc,errno.h"
prim__EDQUOT : Int32
||| The `EDQUOT` errno value.
%inline public export
EDQUOT : Errno
EDQUOT = MkErrno prim__EDQUOT

%inline %foreign "CExpr:(EEXIST),libc,errno.h"
prim__EEXIST : Int32
||| The `EEXIST` errno value.
%inline public export
EEXIST : Errno
EEXIST = MkErrno prim__EEXIST

%inline %foreign "CExpr:(EFAULT),libc,errno.h"
prim__EFAULT : Int32
||| The `EFAULT` errno value.
%inline public export
EFAULT : Errno
EFAULT = MkErrno prim__EFAULT

%inline %foreign "CExpr:(EFBIG),libc,errno.h"
prim__EFBIG : Int32
||| The `EFBIG` errno value.
%inline public export
EFBIG : Errno
EFBIG = MkErrno prim__EFBIG

%inline %foreign "CExpr:(EHOSTDOWN),libc,errno.h"
prim__EHOSTDOWN : Int32
||| The `EHOSTDOWN` errno value.
|||
||| Linux and BSD, not in POSIX; see `errno(3)`.
%inline public export
EHOSTDOWN : Errno
EHOSTDOWN = MkErrno prim__EHOSTDOWN

%inline %foreign "CExpr:(EHOSTUNREACH),libc,errno.h"
prim__EHOSTUNREACH : Int32
||| The `EHOSTUNREACH` errno value.
%inline public export
EHOSTUNREACH : Errno
EHOSTUNREACH = MkErrno prim__EHOSTUNREACH

%inline %foreign "CExpr:(EHWPOISON),libc,errno.h"
prim__EHWPOISON : Int32
||| The `EHWPOISON` errno value.
|||
||| Linux only, not in POSIX; see `errno(3)`.
%inline public export
EHWPOISON : Errno
EHWPOISON = MkErrno prim__EHWPOISON

%inline %foreign "CExpr:(EIDRM),libc,errno.h"
prim__EIDRM : Int32
||| The `EIDRM` errno value.
%inline public export
EIDRM : Errno
EIDRM = MkErrno prim__EIDRM

%inline %foreign "CExpr:(EILSEQ),libc,errno.h"
prim__EILSEQ : Int32
||| The `EILSEQ` errno value.
%inline public export
EILSEQ : Errno
EILSEQ = MkErrno prim__EILSEQ

%inline %foreign "CExpr:(EINPROGRESS),libc,errno.h"
prim__EINPROGRESS : Int32
||| The `EINPROGRESS` errno value.
%inline public export
EINPROGRESS : Errno
EINPROGRESS = MkErrno prim__EINPROGRESS

%inline %foreign "CExpr:(EINTR),libc,errno.h"
prim__EINTR : Int32
||| The `EINTR` errno value.
%inline public export
EINTR : Errno
EINTR = MkErrno prim__EINTR

%inline %foreign "CExpr:(EINVAL),libc,errno.h"
prim__EINVAL : Int32
||| The `EINVAL` errno value.
%inline public export
EINVAL : Errno
EINVAL = MkErrno prim__EINVAL

%inline %foreign "CExpr:(EIO),libc,errno.h"
prim__EIO : Int32
||| The `EIO` errno value.
%inline public export
EIO : Errno
EIO = MkErrno prim__EIO

%inline %foreign "CExpr:(EISCONN),libc,errno.h"
prim__EISCONN : Int32
||| The `EISCONN` errno value.
%inline public export
EISCONN : Errno
EISCONN = MkErrno prim__EISCONN

%inline %foreign "CExpr:(EISDIR),libc,errno.h"
prim__EISDIR : Int32
||| The `EISDIR` errno value.
%inline public export
EISDIR : Errno
EISDIR = MkErrno prim__EISDIR

%inline %foreign "CExpr:(EISNAM),libc,errno.h"
prim__EISNAM : Int32
||| The `EISNAM` errno value.
|||
||| Linux only, not in POSIX; see `errno(3)`.
%inline public export
EISNAM : Errno
EISNAM = MkErrno prim__EISNAM

%inline %foreign "CExpr:(EKEYEXPIRED),libc,errno.h"
prim__EKEYEXPIRED : Int32
||| The `EKEYEXPIRED` errno value.
|||
||| Linux only, not in POSIX; see `errno(3)`.
%inline public export
EKEYEXPIRED : Errno
EKEYEXPIRED = MkErrno prim__EKEYEXPIRED

%inline %foreign "CExpr:(EKEYREJECTED),libc,errno.h"
prim__EKEYREJECTED : Int32
||| The `EKEYREJECTED` errno value.
|||
||| Linux only, not in POSIX; see `errno(3)`.
%inline public export
EKEYREJECTED : Errno
EKEYREJECTED = MkErrno prim__EKEYREJECTED

%inline %foreign "CExpr:(EKEYREVOKED),libc,errno.h"
prim__EKEYREVOKED : Int32
||| The `EKEYREVOKED` errno value.
|||
||| Linux only, not in POSIX; see `errno(3)`.
%inline public export
EKEYREVOKED : Errno
EKEYREVOKED = MkErrno prim__EKEYREVOKED

%inline %foreign "CExpr:(EL2HLT),libc,errno.h"
prim__EL2HLT : Int32
||| The `EL2HLT` errno value.
|||
||| Linux only, not in POSIX; see `errno(3)`.
%inline public export
EL2HLT : Errno
EL2HLT = MkErrno prim__EL2HLT

%inline %foreign "CExpr:(EL2NSYNC),libc,errno.h"
prim__EL2NSYNC : Int32
||| The `EL2NSYNC` errno value.
|||
||| Linux only, not in POSIX; see `errno(3)`.
%inline public export
EL2NSYNC : Errno
EL2NSYNC = MkErrno prim__EL2NSYNC

%inline %foreign "CExpr:(EL3HLT),libc,errno.h"
prim__EL3HLT : Int32
||| The `EL3HLT` errno value.
|||
||| Linux only, not in POSIX; see `errno(3)`.
%inline public export
EL3HLT : Errno
EL3HLT = MkErrno prim__EL3HLT

%inline %foreign "CExpr:(EL3RST),libc,errno.h"
prim__EL3RST : Int32
||| The `EL3RST` errno value.
|||
||| Linux only, not in POSIX; see `errno(3)`.
%inline public export
EL3RST : Errno
EL3RST = MkErrno prim__EL3RST

%inline %foreign "CExpr:(ELIBACC),libc,errno.h"
prim__ELIBACC : Int32
||| The `ELIBACC` errno value.
|||
||| Linux only, not in POSIX; see `errno(3)`.
%inline public export
ELIBACC : Errno
ELIBACC = MkErrno prim__ELIBACC

%inline %foreign "CExpr:(ELIBBAD),libc,errno.h"
prim__ELIBBAD : Int32
||| The `ELIBBAD` errno value.
|||
||| Linux only, not in POSIX; see `errno(3)`.
%inline public export
ELIBBAD : Errno
ELIBBAD = MkErrno prim__ELIBBAD

%inline %foreign "CExpr:(ELIBMAX),libc,errno.h"
prim__ELIBMAX : Int32
||| The `ELIBMAX` errno value.
|||
||| Linux only, not in POSIX; see `errno(3)`.
%inline public export
ELIBMAX : Errno
ELIBMAX = MkErrno prim__ELIBMAX

%inline %foreign "CExpr:(ELIBSCN),libc,errno.h"
prim__ELIBSCN : Int32
||| The `ELIBSCN` errno value.
|||
||| Linux only, not in POSIX; see `errno(3)`.
%inline public export
ELIBSCN : Errno
ELIBSCN = MkErrno prim__ELIBSCN

%inline %foreign "CExpr:(ELIBEXEC),libc,errno.h"
prim__ELIBEXEC : Int32
||| The `ELIBEXEC` errno value.
|||
||| Linux only, not in POSIX; see `errno(3)`.
%inline public export
ELIBEXEC : Errno
ELIBEXEC = MkErrno prim__ELIBEXEC

%inline %foreign "CExpr:(ELOOP),libc,errno.h"
prim__ELOOP : Int32
||| The `ELOOP` errno value.
%inline public export
ELOOP : Errno
ELOOP = MkErrno prim__ELOOP

%inline %foreign "CExpr:(EMEDIUMTYPE),libc,errno.h"
prim__EMEDIUMTYPE : Int32
||| The `EMEDIUMTYPE` errno value.
|||
||| Linux only, not in POSIX; see `errno(3)`.
%inline public export
EMEDIUMTYPE : Errno
EMEDIUMTYPE = MkErrno prim__EMEDIUMTYPE

%inline %foreign "CExpr:(EMFILE),libc,errno.h"
prim__EMFILE : Int32
||| The `EMFILE` errno value.
%inline public export
EMFILE : Errno
EMFILE = MkErrno prim__EMFILE

%inline %foreign "CExpr:(EMLINK),libc,errno.h"
prim__EMLINK : Int32
||| The `EMLINK` errno value.
%inline public export
EMLINK : Errno
EMLINK = MkErrno prim__EMLINK

%inline %foreign "CExpr:(EMSGSIZE),libc,errno.h"
prim__EMSGSIZE : Int32
||| The `EMSGSIZE` errno value.
%inline public export
EMSGSIZE : Errno
EMSGSIZE = MkErrno prim__EMSGSIZE

%inline %foreign "CExpr:(EMULTIHOP),libc,errno.h"
prim__EMULTIHOP : Int32
||| The `EMULTIHOP` errno value.
%inline public export
EMULTIHOP : Errno
EMULTIHOP = MkErrno prim__EMULTIHOP

%inline %foreign "CExpr:(ENAMETOOLONG),libc,errno.h"
prim__ENAMETOOLONG : Int32
||| The `ENAMETOOLONG` errno value.
%inline public export
ENAMETOOLONG : Errno
ENAMETOOLONG = MkErrno prim__ENAMETOOLONG

%inline %foreign "CExpr:(ENETDOWN),libc,errno.h"
prim__ENETDOWN : Int32
||| The `ENETDOWN` errno value.
%inline public export
ENETDOWN : Errno
ENETDOWN = MkErrno prim__ENETDOWN

%inline %foreign "CExpr:(ENETRESET),libc,errno.h"
prim__ENETRESET : Int32
||| The `ENETRESET` errno value.
%inline public export
ENETRESET : Errno
ENETRESET = MkErrno prim__ENETRESET

%inline %foreign "CExpr:(ENETUNREACH),libc,errno.h"
prim__ENETUNREACH : Int32
||| The `ENETUNREACH` errno value.
%inline public export
ENETUNREACH : Errno
ENETUNREACH = MkErrno prim__ENETUNREACH

%inline %foreign "CExpr:(ENFILE),libc,errno.h"
prim__ENFILE : Int32
||| The `ENFILE` errno value.
%inline public export
ENFILE : Errno
ENFILE = MkErrno prim__ENFILE

%inline %foreign "CExpr:(ENOANO),libc,errno.h"
prim__ENOANO : Int32
||| The `ENOANO` errno value.
|||
||| Linux only, not in POSIX; see `errno(3)`.
%inline public export
ENOANO : Errno
ENOANO = MkErrno prim__ENOANO

%inline %foreign "CExpr:(ENOBUFS),libc,errno.h"
prim__ENOBUFS : Int32
||| The `ENOBUFS` errno value.
%inline public export
ENOBUFS : Errno
ENOBUFS = MkErrno prim__ENOBUFS

%inline %foreign "CExpr:(ENODATA),libc,errno.h"
prim__ENODATA : Int32
||| The `ENODATA` errno value.
%inline public export
ENODATA : Errno
ENODATA = MkErrno prim__ENODATA

%inline %foreign "CExpr:(ENODEV),libc,errno.h"
prim__ENODEV : Int32
||| The `ENODEV` errno value.
%inline public export
ENODEV : Errno
ENODEV = MkErrno prim__ENODEV

%inline %foreign "CExpr:(ENOENT),libc,errno.h"
prim__ENOENT : Int32
||| The `ENOENT` errno value.
%inline public export
ENOENT : Errno
ENOENT = MkErrno prim__ENOENT

%inline %foreign "CExpr:(ENOEXEC),libc,errno.h"
prim__ENOEXEC : Int32
||| The `ENOEXEC` errno value.
%inline public export
ENOEXEC : Errno
ENOEXEC = MkErrno prim__ENOEXEC

%inline %foreign "CExpr:(ENOKEY),libc,errno.h"
prim__ENOKEY : Int32
||| The `ENOKEY` errno value.
|||
||| Linux only, not in POSIX; see `errno(3)`.
%inline public export
ENOKEY : Errno
ENOKEY = MkErrno prim__ENOKEY

%inline %foreign "CExpr:(ENOLCK),libc,errno.h"
prim__ENOLCK : Int32
||| The `ENOLCK` errno value.
%inline public export
ENOLCK : Errno
ENOLCK = MkErrno prim__ENOLCK

%inline %foreign "CExpr:(ENOLINK),libc,errno.h"
prim__ENOLINK : Int32
||| The `ENOLINK` errno value.
%inline public export
ENOLINK : Errno
ENOLINK = MkErrno prim__ENOLINK

%inline %foreign "CExpr:(ENOMEDIUM),libc,errno.h"
prim__ENOMEDIUM : Int32
||| The `ENOMEDIUM` errno value.
|||
||| Linux only, not in POSIX; see `errno(3)`.
%inline public export
ENOMEDIUM : Errno
ENOMEDIUM = MkErrno prim__ENOMEDIUM

%inline %foreign "CExpr:(ENOMEM),libc,errno.h"
prim__ENOMEM : Int32
||| The `ENOMEM` errno value.
%inline public export
ENOMEM : Errno
ENOMEM = MkErrno prim__ENOMEM

%inline %foreign "CExpr:(ENOMSG),libc,errno.h"
prim__ENOMSG : Int32
||| The `ENOMSG` errno value.
%inline public export
ENOMSG : Errno
ENOMSG = MkErrno prim__ENOMSG

%inline %foreign "CExpr:(ENONET),libc,errno.h"
prim__ENONET : Int32
||| The `ENONET` errno value.
|||
||| Linux only, not in POSIX; see `errno(3)`.
%inline public export
ENONET : Errno
ENONET = MkErrno prim__ENONET

%inline %foreign "CExpr:(ENOPKG),libc,errno.h"
prim__ENOPKG : Int32
||| The `ENOPKG` errno value.
|||
||| Linux only, not in POSIX; see `errno(3)`.
%inline public export
ENOPKG : Errno
ENOPKG = MkErrno prim__ENOPKG

%inline %foreign "CExpr:(ENOPROTOOPT),libc,errno.h"
prim__ENOPROTOOPT : Int32
||| The `ENOPROTOOPT` errno value.
%inline public export
ENOPROTOOPT : Errno
ENOPROTOOPT = MkErrno prim__ENOPROTOOPT

%inline %foreign "CExpr:(ENOSPC),libc,errno.h"
prim__ENOSPC : Int32
||| The `ENOSPC` errno value.
%inline public export
ENOSPC : Errno
ENOSPC = MkErrno prim__ENOSPC

%inline %foreign "CExpr:(ENOSR),libc,errno.h"
prim__ENOSR : Int32
||| The `ENOSR` errno value.
%inline public export
ENOSR : Errno
ENOSR = MkErrno prim__ENOSR

%inline %foreign "CExpr:(ENOSTR),libc,errno.h"
prim__ENOSTR : Int32
||| The `ENOSTR` errno value.
%inline public export
ENOSTR : Errno
ENOSTR = MkErrno prim__ENOSTR

%inline %foreign "CExpr:(ENOSYS),libc,errno.h"
prim__ENOSYS : Int32
||| The `ENOSYS` errno value.
%inline public export
ENOSYS : Errno
ENOSYS = MkErrno prim__ENOSYS

%inline %foreign "CExpr:(ENOTBLK),libc,errno.h"
prim__ENOTBLK : Int32
||| The `ENOTBLK` errno value.
|||
||| Linux and BSD, not in POSIX; see `errno(3)`.
%inline public export
ENOTBLK : Errno
ENOTBLK = MkErrno prim__ENOTBLK

%inline %foreign "CExpr:(ENOTCONN),libc,errno.h"
prim__ENOTCONN : Int32
||| The `ENOTCONN` errno value.
%inline public export
ENOTCONN : Errno
ENOTCONN = MkErrno prim__ENOTCONN

%inline %foreign "CExpr:(ENOTDIR),libc,errno.h"
prim__ENOTDIR : Int32
||| The `ENOTDIR` errno value.
%inline public export
ENOTDIR : Errno
ENOTDIR = MkErrno prim__ENOTDIR

%inline %foreign "CExpr:(ENOTEMPTY),libc,errno.h"
prim__ENOTEMPTY : Int32
||| The `ENOTEMPTY` errno value.
%inline public export
ENOTEMPTY : Errno
ENOTEMPTY = MkErrno prim__ENOTEMPTY

%inline %foreign "CExpr:(ENOTRECOVERABLE),libc,errno.h"
prim__ENOTRECOVERABLE : Int32
||| The `ENOTRECOVERABLE` errno value.
%inline public export
ENOTRECOVERABLE : Errno
ENOTRECOVERABLE = MkErrno prim__ENOTRECOVERABLE

%inline %foreign "CExpr:(ENOTSOCK),libc,errno.h"
prim__ENOTSOCK : Int32
||| The `ENOTSOCK` errno value.
%inline public export
ENOTSOCK : Errno
ENOTSOCK = MkErrno prim__ENOTSOCK

%inline %foreign "CExpr:(ENOTSUP),libc,errno.h"
prim__ENOTSUP : Int32
||| The `ENOTSUP` errno value.
%inline public export
ENOTSUP : Errno
ENOTSUP = MkErrno prim__ENOTSUP

%inline %foreign "CExpr:(ENOTTY),libc,errno.h"
prim__ENOTTY : Int32
||| The `ENOTTY` errno value.
%inline public export
ENOTTY : Errno
ENOTTY = MkErrno prim__ENOTTY

%inline %foreign "CExpr:(ENOTUNIQ),libc,errno.h"
prim__ENOTUNIQ : Int32
||| The `ENOTUNIQ` errno value.
|||
||| Linux only, not in POSIX; see `errno(3)`.
%inline public export
ENOTUNIQ : Errno
ENOTUNIQ = MkErrno prim__ENOTUNIQ

%inline %foreign "CExpr:(ENXIO),libc,errno.h"
prim__ENXIO : Int32
||| The `ENXIO` errno value.
%inline public export
ENXIO : Errno
ENXIO = MkErrno prim__ENXIO

%inline %foreign "CExpr:(EOPNOTSUPP),libc,errno.h"
prim__EOPNOTSUPP : Int32
||| The `EOPNOTSUPP` errno value.
%inline public export
EOPNOTSUPP : Errno
EOPNOTSUPP = MkErrno prim__EOPNOTSUPP

%inline %foreign "CExpr:(EOVERFLOW),libc,errno.h"
prim__EOVERFLOW : Int32
||| The `EOVERFLOW` errno value.
%inline public export
EOVERFLOW : Errno
EOVERFLOW = MkErrno prim__EOVERFLOW

%inline %foreign "CExpr:(EOWNERDEAD),libc,errno.h"
prim__EOWNERDEAD : Int32
||| The `EOWNERDEAD` errno value.
%inline public export
EOWNERDEAD : Errno
EOWNERDEAD = MkErrno prim__EOWNERDEAD

%inline %foreign "CExpr:(EPERM),libc,errno.h"
prim__EPERM : Int32
||| The `EPERM` errno value.
%inline public export
EPERM : Errno
EPERM = MkErrno prim__EPERM

%inline %foreign "CExpr:(EPFNOSUPPORT),libc,errno.h"
prim__EPFNOSUPPORT : Int32
||| The `EPFNOSUPPORT` errno value.
|||
||| Linux and BSD, not in POSIX; see `errno(3)`.
%inline public export
EPFNOSUPPORT : Errno
EPFNOSUPPORT = MkErrno prim__EPFNOSUPPORT

%inline %foreign "CExpr:(EPIPE),libc,errno.h"
prim__EPIPE : Int32
||| The `EPIPE` errno value.
%inline public export
EPIPE : Errno
EPIPE = MkErrno prim__EPIPE

%inline %foreign "CExpr:(EPROTO),libc,errno.h"
prim__EPROTO : Int32
||| The `EPROTO` errno value.
%inline public export
EPROTO : Errno
EPROTO = MkErrno prim__EPROTO

%inline %foreign "CExpr:(EPROTONOSUPPORT),libc,errno.h"
prim__EPROTONOSUPPORT : Int32
||| The `EPROTONOSUPPORT` errno value.
%inline public export
EPROTONOSUPPORT : Errno
EPROTONOSUPPORT = MkErrno prim__EPROTONOSUPPORT

%inline %foreign "CExpr:(EPROTOTYPE),libc,errno.h"
prim__EPROTOTYPE : Int32
||| The `EPROTOTYPE` errno value.
%inline public export
EPROTOTYPE : Errno
EPROTOTYPE = MkErrno prim__EPROTOTYPE

%inline %foreign "CExpr:(ERANGE),libc,errno.h"
prim__ERANGE : Int32
||| The `ERANGE` errno value.
%inline public export
ERANGE : Errno
ERANGE = MkErrno prim__ERANGE

%inline %foreign "CExpr:(EREMCHG),libc,errno.h"
prim__EREMCHG : Int32
||| The `EREMCHG` errno value.
|||
||| Linux only, not in POSIX; see `errno(3)`.
%inline public export
EREMCHG : Errno
EREMCHG = MkErrno prim__EREMCHG

%inline %foreign "CExpr:(EREMOTE),libc,errno.h"
prim__EREMOTE : Int32
||| The `EREMOTE` errno value.
|||
||| Linux and BSD, not in POSIX; see `errno(3)`.
%inline public export
EREMOTE : Errno
EREMOTE = MkErrno prim__EREMOTE

%inline %foreign "CExpr:(EREMOTEIO),libc,errno.h"
prim__EREMOTEIO : Int32
||| The `EREMOTEIO` errno value.
|||
||| Linux only, not in POSIX; see `errno(3)`.
%inline public export
EREMOTEIO : Errno
EREMOTEIO = MkErrno prim__EREMOTEIO

%inline %foreign "CExpr:(ERESTART),libc,errno.h"
prim__ERESTART : Int32
||| The `ERESTART` errno value.
|||
||| Linux only, not in POSIX; see `errno(3)`.
%inline public export
ERESTART : Errno
ERESTART = MkErrno prim__ERESTART

%inline %foreign "CExpr:(ERFKILL),libc,errno.h"
prim__ERFKILL : Int32
||| The `ERFKILL` errno value.
|||
||| Linux only, not in POSIX; see `errno(3)`.
%inline public export
ERFKILL : Errno
ERFKILL = MkErrno prim__ERFKILL

%inline %foreign "CExpr:(EROFS),libc,errno.h"
prim__EROFS : Int32
||| The `EROFS` errno value.
%inline public export
EROFS : Errno
EROFS = MkErrno prim__EROFS

%inline %foreign "CExpr:(ESHUTDOWN),libc,errno.h"
prim__ESHUTDOWN : Int32
||| The `ESHUTDOWN` errno value.
|||
||| Linux and BSD, not in POSIX; see `errno(3)`.
%inline public export
ESHUTDOWN : Errno
ESHUTDOWN = MkErrno prim__ESHUTDOWN

%inline %foreign "CExpr:(ESPIPE),libc,errno.h"
prim__ESPIPE : Int32
||| The `ESPIPE` errno value.
%inline public export
ESPIPE : Errno
ESPIPE = MkErrno prim__ESPIPE

%inline %foreign "CExpr:(ESOCKTNOSUPPORT),libc,errno.h"
prim__ESOCKTNOSUPPORT : Int32
||| The `ESOCKTNOSUPPORT` errno value.
|||
||| Linux and BSD, not in POSIX; see `errno(3)`.
%inline public export
ESOCKTNOSUPPORT : Errno
ESOCKTNOSUPPORT = MkErrno prim__ESOCKTNOSUPPORT

%inline %foreign "CExpr:(ESRCH),libc,errno.h"
prim__ESRCH : Int32
||| The `ESRCH` errno value.
%inline public export
ESRCH : Errno
ESRCH = MkErrno prim__ESRCH

%inline %foreign "CExpr:(ESTALE),libc,errno.h"
prim__ESTALE : Int32
||| The `ESTALE` errno value.
%inline public export
ESTALE : Errno
ESTALE = MkErrno prim__ESTALE

%inline %foreign "CExpr:(ESTRPIPE),libc,errno.h"
prim__ESTRPIPE : Int32
||| The `ESTRPIPE` errno value.
|||
||| Linux only, not in POSIX; see `errno(3)`.
%inline public export
ESTRPIPE : Errno
ESTRPIPE = MkErrno prim__ESTRPIPE

%inline %foreign "CExpr:(ETIME),libc,errno.h"
prim__ETIME : Int32
||| The `ETIME` errno value.
%inline public export
ETIME : Errno
ETIME = MkErrno prim__ETIME

%inline %foreign "CExpr:(ETIMEDOUT),libc,errno.h"
prim__ETIMEDOUT : Int32
||| The `ETIMEDOUT` errno value.
%inline public export
ETIMEDOUT : Errno
ETIMEDOUT = MkErrno prim__ETIMEDOUT

%inline %foreign "CExpr:(ETOOMANYREFS),libc,errno.h"
prim__ETOOMANYREFS : Int32
||| The `ETOOMANYREFS` errno value.
|||
||| Linux and BSD, not in POSIX; see `errno(3)`.
%inline public export
ETOOMANYREFS : Errno
ETOOMANYREFS = MkErrno prim__ETOOMANYREFS

%inline %foreign "CExpr:(ETXTBSY),libc,errno.h"
prim__ETXTBSY : Int32
||| The `ETXTBSY` errno value.
%inline public export
ETXTBSY : Errno
ETXTBSY = MkErrno prim__ETXTBSY

%inline %foreign "CExpr:(EUCLEAN),libc,errno.h"
prim__EUCLEAN : Int32
||| The `EUCLEAN` errno value.
|||
||| Linux only, not in POSIX; see `errno(3)`.
%inline public export
EUCLEAN : Errno
EUCLEAN = MkErrno prim__EUCLEAN

%inline %foreign "CExpr:(EUNATCH),libc,errno.h"
prim__EUNATCH : Int32
||| The `EUNATCH` errno value.
|||
||| Linux only, not in POSIX; see `errno(3)`.
%inline public export
EUNATCH : Errno
EUNATCH = MkErrno prim__EUNATCH

%inline %foreign "CExpr:(EUSERS),libc,errno.h"
prim__EUSERS : Int32
||| The `EUSERS` errno value.
|||
||| Linux and BSD, not in POSIX; see `errno(3)`.
%inline public export
EUSERS : Errno
EUSERS = MkErrno prim__EUSERS

%inline %foreign "CExpr:(EWOULDBLOCK),libc,errno.h"
prim__EWOULDBLOCK : Int32
||| The `EWOULDBLOCK` errno value.
%inline public export
EWOULDBLOCK : Errno
EWOULDBLOCK = MkErrno prim__EWOULDBLOCK

%inline %foreign "CExpr:(EXDEV),libc,errno.h"
prim__EXDEV : Int32
||| The `EXDEV` errno value.
%inline public export
EXDEV : Errno
EXDEV = MkErrno prim__EXDEV

%inline %foreign "CExpr:(EXFULL),libc,errno.h"
prim__EXFULL : Int32
||| The `EXFULL` errno value.
|||
||| Linux only, not in POSIX; see `errno(3)`.
%inline public export
EXFULL : Errno
EXFULL = MkErrno prim__EXFULL

