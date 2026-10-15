||| `eventfd`: a counter that is read and written through a file descriptor, so
||| it can be waited on with `poll` or `System.Linux.Epoll` (a thread wakes
||| another by writing to it).
|||
||| Linux only.
module System.Linux.Eventfd

import System.FFI
import System.Posix.Errno
import System.Posix.FileDesc

%default total

||| Close the descriptor on `exec`.
%inline %foreign "CExpr:(EFD_CLOEXEC),libc,sys/eventfd.h"
export EFD_CLOEXEC : Int32
||| A read of a counter that is 0, or a write that would overflow it, fails with
||| `EAGAIN` instead of blocking.
%inline %foreign "CExpr:(EFD_NONBLOCK),libc,sys/eventfd.h"
export EFD_NONBLOCK : Int32
||| A read takes 1 off the counter and returns 1, instead of returning the
||| counter and clearing it.
%inline %foreign "CExpr:(EFD_SEMAPHORE),libc,sys/eventfd.h"
export EFD_SEMAPHORE : Int32

%inline %foreign "CExpr:(eventfd($1, $2)),libc,sys/eventfd.h"
prim__eventfd : Bits32 -> Int32 -> PrimIO Int32
%inline %foreign "CExpr:(read($1, $2, 8)),libc,unistd.h"
prim__read8 : Int32 -> AnyPtr -> PrimIO Int64
%inline %foreign "CExpr:(write($1, $2, 8)),libc,unistd.h"
prim__write8 : Int32 -> AnyPtr -> PrimIO Int64
%inline %foreign "CExpr:(*(uint64_t *)($1)),libc,stdint.h"
prim__u64At : AnyPtr -> PrimIO Bits64
%inline %foreign "CExpr:(*(uint64_t *)($1) = ($2)),libc,stdint.h"
prim__setU64 : AnyPtr -> Bits64 -> PrimIO Bits64

||| Create a counter that starts at `initval`. `flags` is an `or` of the `EFD_*` values.
export
eventfd : (initval : Bits32) -> (flags : Int32) -> IO (Either Errno FileDesc)
eventfd initval flags = primIO (prim__eventfd initval flags) >>= primFdToFileDesc

||| Read the counter and reset it to 0 (with `EFD_SEMAPHORE`: take 1 off and
||| return 1). Blocks while the counter is 0, or `Left EAGAIN` with `EFD_NONBLOCK`.
export
eventfdRead : FileDesc -> IO (Either Errno Bits64)
eventfdRead fd = do
  p <- malloc 8
  n <- primIO (prim__read8 fd.rawfd p)
  res <- if n < 0 then Left <$> errno else Right <$> primIO (prim__u64At p)
  free p
  pure res

||| Add to the counter. Blocks when the sum would pass `0xfffffffffffffffe`, or
||| `Left EAGAIN` with `EFD_NONBLOCK`.
export
eventfdWrite : FileDesc -> Bits64 -> IO (Either Errno ())
eventfdWrite fd value = do
  p <- malloc 8
  _ <- primIO (prim__setU64 p value)
  n <- primIO (prim__write8 fd.rawfd p)
  res <- if n < 0 then Left <$> errno else pure (Right ())
  free p
  pure res
