||| `signalfd`: take signals as values read from a file descriptor. Block the
||| signals first (`System.Posix.Signal.sigprocmask`), or they are delivered
||| the ordinary way.
|||
||| Linux only.
module System.Linux.Signalfd

import System.FFI
import System.Posix.Errno
import System.Posix.FileDesc
import System.Posix.Signal

%default total

%inline %foreign "CExpr:(SFD_NONBLOCK),libc,sys/signalfd.h"
export SFD_NONBLOCK : Bits32
%inline %foreign "CExpr:(SFD_CLOEXEC),libc,sys/signalfd.h"
export SFD_CLOEXEC : Bits32

||| A signal read from a `signalfd` (some of the fields of `struct signalfd_siginfo`).
public export
record SignalInfo where
  constructor MkSignalInfo
  signo : Signal
  errnoValue : Int32
  code : Int32
  pid : Bits32
  uid : Bits32
  fd : Int32
  status : Int32
  intValue : Int32

export
Show SignalInfo where
  show i = "SignalInfo " ++ show i.signo ++ " code=" ++ show i.code ++ " pid=" ++ show i.pid
        ++ " uid=" ++ show i.uid ++ " status=" ++ show i.status ++ " int=" ++ show i.intValue

%inline %foreign "CExpr:(signalfd($1, (sigset_t *)($2), $3)),libc,sys/signalfd.h"
prim__signalfd : Int32 -> GCPtr RawSigSet -> Bits32 -> PrimIO Int32
%inline %foreign "CExpr:(sizeof(struct signalfd_siginfo)),libc,sys/signalfd.h"
prim__sizeofInfo : Int
%inline %foreign "CExpr:(read($1, $2, sizeof(struct signalfd_siginfo))),libc,sys/signalfd.h;unistd.h"
prim__readInfo : Int32 -> AnyPtr -> PrimIO Int64
%inline %foreign "CExpr:(((struct signalfd_siginfo *)($1))->ssi_signo),libc,sys/signalfd.h"
prim__ssi_signo : AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(((struct signalfd_siginfo *)($1))->ssi_errno),libc,sys/signalfd.h"
prim__ssi_errno : AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(((struct signalfd_siginfo *)($1))->ssi_code),libc,sys/signalfd.h"
prim__ssi_code : AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(((struct signalfd_siginfo *)($1))->ssi_pid),libc,sys/signalfd.h"
prim__ssi_pid : AnyPtr -> PrimIO Bits32
%inline %foreign "CExpr:(((struct signalfd_siginfo *)($1))->ssi_uid),libc,sys/signalfd.h"
prim__ssi_uid : AnyPtr -> PrimIO Bits32
%inline %foreign "CExpr:(((struct signalfd_siginfo *)($1))->ssi_fd),libc,sys/signalfd.h"
prim__ssi_fd : AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(((struct signalfd_siginfo *)($1))->ssi_status),libc,sys/signalfd.h"
prim__ssi_status : AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(((struct signalfd_siginfo *)($1))->ssi_int),libc,sys/signalfd.h"
prim__ssi_int : AnyPtr -> PrimIO Int32

||| Create a descriptor from which the signals of the set can be read
||| (`flags`: `SFD_NONBLOCK`, `SFD_CLOEXEC`).
export
signalfd : SigSet -> (flags : Bits32) -> IO (Either Errno FileDesc)
signalfd s flags = do
  r <- primIO (prim__signalfd (-1) s flags)
  primFdToFileDesc r

||| Change the set of an existing `signalfd` (`flags` is ignored by Linux for an
||| existing descriptor; it is kept to match `signalfd(2)`).
export
signalfdSet : FileDesc -> SigSet -> (flags : Bits32) -> IO (Either Errno ())
signalfdSet fd s flags = do
  r <- primIO (prim__signalfd fd.rawfd s flags)
  map (map (const ())) (checkNonNeg r)

||| Take the next pending signal. Blocks until there is one, or `Left EAGAIN`
||| for a `SFD_NONBLOCK` descriptor with none.
export
readSignal : FileDesc -> IO (Either Errno SignalInfo)
readSignal fd = do
  p <- malloc prim__sizeofInfo
  n <- primIO (prim__readInfo fd.rawfd p)
  res <- if n >= 0
            then do a <- primIO (prim__ssi_signo p)
                    b <- primIO (prim__ssi_errno p)
                    c <- primIO (prim__ssi_code p)
                    d <- primIO (prim__ssi_pid p)
                    e <- primIO (prim__ssi_uid p)
                    f <- primIO (prim__ssi_fd p)
                    g <- primIO (prim__ssi_status p)
                    h <- primIO (prim__ssi_int p)
                    pure (Right (MkSignalInfo (MkSignal a) b c d e f g h))
            else Left <$> errno
  free p
  pure res
