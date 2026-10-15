||| Pipes and `fcntl`: `pipe`, descriptor flags (`FD_CLOEXEC`), status flags
||| (`O_NONBLOCK`, `O_APPEND`, ... from `System.Posix.File`) and `F_DUPFD`.
|||
||| `pipe2` (Linux, BSD) is in `System.Linux.Pipe`.
module System.Posix.Fcntl

import System.FFI
import System.Posix.Errno
import System.Posix.FileDesc

%default total

%inline %foreign "CExpr:(2 * sizeof(int)),libc,unistd.h"
prim__sizeofIntPair : Int
%inline %foreign "CExpr:(pipe((int *)($1))),libc,unistd.h"
prim__pipe : AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(((int *)($1))[$2]),libc,unistd.h"
prim__intAt : AnyPtr -> Int -> PrimIO Int32

||| Run a call that fills an `int[2]` of descriptors (`pipe`, `pipe2`): the
||| read end and the write end, or the `errno`.
export
withFdPair : (AnyPtr -> PrimIO Int32) -> IO (Either Errno (FileDesc, FileDesc))
withFdPair call = do
  p <- malloc prim__sizeofIntPair
  rc <- primIO (call p)
  res <- if rc == 0
            then do r <- primIO (prim__intAt p 0)
                    w <- primIO (prim__intAt p 1)
                    -- `pipe` and `pipe2` give two non-negative numbers when they succeed;
                    -- `EBADF` (and an open descriptor left behind) is unreachable.
                    pure (maybe (Left EBADF) Right (MkPair <$> mkFileDesc r <*> mkFileDesc w))
            else Left <$> errno
  free p
  pure res

||| Create a pipe; returns the read end and the write end.
export
pipe : IO (Either Errno (FileDesc, FileDesc))
pipe = withFdPair prim__pipe

%inline %foreign "CExpr:(F_GETFD),libc,fcntl.h"
prim__F_GETFD : Int32
%inline %foreign "CExpr:(F_SETFD),libc,fcntl.h"
prim__F_SETFD : Int32
%inline %foreign "CExpr:(F_GETFL),libc,fcntl.h"
prim__F_GETFL : Int32
%inline %foreign "CExpr:(F_SETFL),libc,fcntl.h"
prim__F_SETFL : Int32
%inline %foreign "CExpr:(F_DUPFD),libc,fcntl.h"
prim__F_DUPFD : Int32
%inline %foreign "CExpr:(F_DUPFD_CLOEXEC),libc,fcntl.h"
prim__F_DUPFD_CLOEXEC : Int32

||| Descriptor flag: close the descriptor on `exec`.
%inline %foreign "CExpr:(FD_CLOEXEC),libc,fcntl.h"
export FD_CLOEXEC : Bits32

%inline %foreign "CExpr:(fcntl($1, $2, $3)),libc,fcntl.h"
prim__fcntl : Int32 -> Int32 -> Int64 -> PrimIO Int32

||| The descriptor flags (`FD_CLOEXEC`).
export
getFdFlags : FileDesc -> IO (Either Errno Bits32)
getFdFlags fd = do
  r <- primIO (prim__fcntl fd.rawfd prim__F_GETFD 0)
  map (map cast) (checkNonNeg r)

||| Set the descriptor flags (`FD_CLOEXEC`).
export
setFdFlags : FileDesc -> Bits32 -> IO (Either Errno ())
setFdFlags fd flags = primIO (prim__fcntl fd.rawfd prim__F_SETFD (cast flags)) >>= checkUnit

||| The file status flags (`O_APPEND`, `O_NONBLOCK`, ... and the access mode).
export
getStatusFlags : FileDesc -> IO (Either Errno Bits32)
getStatusFlags fd = do
  r <- primIO (prim__fcntl fd.rawfd prim__F_GETFL 0)
  map (map cast) (checkNonNeg r)

||| Set the file status flags (only `O_APPEND`, `O_NONBLOCK` and a few others can change).
export
setStatusFlags : FileDesc -> Bits32 -> IO (Either Errno ())
setStatusFlags fd flags = primIO (prim__fcntl fd.rawfd prim__F_SETFL (cast flags)) >>= checkUnit

||| Duplicate a descriptor onto the lowest free number that is at least `minimum`.
export
dupfd : FileDesc -> (minimum : Bits32) -> IO (Either Errno FileDesc)
dupfd fd minimum = do
  r <- primIO (prim__fcntl fd.rawfd prim__F_DUPFD (cast minimum))
  primFdToFileDesc r

||| Like `dupfd`, with `FD_CLOEXEC` set on the new descriptor.
export
dupfdCloexec : FileDesc -> (minimum : Bits32) -> IO (Either Errno FileDesc)
dupfdCloexec fd minimum = do
  r <- primIO (prim__fcntl fd.rawfd prim__F_DUPFD_CLOEXEC (cast minimum))
  primFdToFileDesc r
