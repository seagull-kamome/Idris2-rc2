module System.Posix.Uio

import Data.Buffer
import Data.String
import Data.String.RC2
import public System.Posix.FileDesc
import System.FFI
import System.Posix.Errno
import System.FFI.C.Ptr

-------------------------------------------------------------------------------
-- 

||| A POSIX `struct iovec` describing a byte range for vector I/O.
public export
IOVec : Type
IOVec = Struct "unistd_iovec" [("iov_base", AnyPtr), ("iov_len", Bits64)]

||| `sizeof(struct iovec)`: the size of one `IOVec` entry.
%inline %foreign "CExpr:(sizeof(struct iovec)),libc,sys/uio.h"
export SizeOfIOVec : Bits64

%inline %foreign "CExpr:(readv($1, (const struct iovec*)$2, $3)),libc,sys/uio.h"
prim__readv : Int32 -> IOVec -> Bits32 -> PrimIO Int64
%inline %foreign "CExpr:(writev($1, (const struct iovec*)$2, $3)),libc,sys/uio.h"
prim__writev : Int32 -> IOVec -> Bits32 -> PrimIO Int64
||| Linux and BSD, not in POSIX.
%inline %foreign "CExpr:(preadv($1, (const struct iovec*)$2, $3, $4)),libc,sys/uio.h"
prim__preadv : Int32 -> IOVec -> Bits32 -> Bits64 -> PrimIO Int64
||| Linux and BSD, not in POSIX.
%inline %foreign "CExpr:(pwritev($1, (const struct iovec*)$2, $3, $4)),libc,sys/uio.h"
prim__pwritev : Int32 -> IOVec -> Bits32 -> Bits64 -> PrimIO Int64
||| `preadv2`.
|||
||| Needs `_GNU_SOURCE`; see "Build flags" in the `System.Posix.File` header.
|||
||| Linux only (kernel 4.6 and later).
%inline %foreign "CExpr:(preadv2($1, (const struct iovec*)$2, $3, $4, $5)),libc,sys/uio.h"
prim__preadv2 : Int32 -> IOVec -> Bits32 -> Bits64 -> Bits32 -> PrimIO Int64
||| `pwritev2`.
|||
||| Needs `_GNU_SOURCE`; see "Build flags" in the `System.Posix.File` header.
|||
||| Linux only (kernel 4.6 and later).
%inline %foreign "CExpr:(pwritev2($1, (const struct iovec*)$2, $3, $4, $5)),libc,sys/uio.h"
prim__pwritev2 : Int32 -> IOVec -> Bits32 -> Bits64 -> Bits32 -> PrimIO Int64


||| Convert a list of raw pointer/length pairs into a temporary `IOVec` buffer.
toIOVec : List (AnyPtr, Bits64) -> IO IOVec
toIOVec xs = do
  raw <- malloc (cast $ 16 * length xs)
  -- `struct iovec` is { void *iov_base; size_t iov_len; }: two words per entry.
  let bases : Ptr AnyPtr = prim__castPtr raw
  let lens : Ptr Bits64 = prim__castPtr raw
  for_ (zip [0 .. cast (length xs)] xs) $ \(i, (p, n)) => do
    unsafePtrStore bases (2 * i) p
    unsafePtrStore lens (2 * i + 1) n
  pure (believe_me raw)




||| Read data from a file descriptor into a list of memory buffers.
public export
readv : FileDesc -> List (AnyPtr, Bits64) -> IO (Either Errno Nat)
readv fd xs = do
  let n : Bits32 := cast {to=Bits32} $ length xs
  iovec <- toIOVec xs
  ret <- primIO $ prim__readv fd.rawfd iovec n
  res <- checkCount ret   -- before `free`, which may touch `errno`
  free $ believe_me iovec
  pure res

||| Write data from a list of memory buffers to a file descriptor.
public export
writev : FileDesc -> List (AnyPtr, Bits64) -> IO (Either Errno Nat)
writev fd xs = do
  let n : Bits32 := cast {to=Bits32} $ length xs
  iovec <- toIOVec xs
  ret <- primIO $ prim__writev fd.rawfd iovec n
  res <- checkCount ret   -- before `free`, which may touch `errno`
  free $ believe_me iovec
  pure res



-------------------------------------------------------------------------------
--  pread/pwrite


namespace AnyPtr
  %inline %foreign "CExpr:(pread($1, $2, $3, $4)),libc,unistd.h"
  prim__pread : Int32 -> AnyPtr -> Bits64 -> Bits64 -> PrimIO Int64

  ||| Read from an arbitrary memory pointer at a specific offset.
  %inline public export
  pread : FileDesc -> AnyPtr -> Bits64-> Bits64 -> IO (Either Errno Nat)
  pread fd buf count offset =
    primIO (prim__pread fd.rawfd buf count offset) >>= checkCount


  %inline %foreign "CExpr:(pwrite($1, $2, $3, $4)),libc,unistd.h"
  prim__pwrite : Int32 -> AnyPtr -> Bits64 -> Bits64 -> PrimIO Int64

  ||| Write to an arbitrary memory pointer at a specific offset.
  %inline public export
  pwrite : FileDesc -> AnyPtr -> Bits64-> Bits64 -> IO (Either Errno Nat)
  pwrite fd buf count offset =
    primIO (prim__pwrite fd.rawfd buf count offset) >>= checkCount


namespace Buffer
  %inline %foreign "CExpr:(pread($1, $2, $3, $4)),libc,unistd.h"
  prim__pread : Int32 -> Buffer -> Bits64 -> Bits64 -> PrimIO Int64

  ||| Read from a buffer at a specific file offset.
  %inline public export
  pread : FileDesc -> Buffer -> Bits64-> Bits64 -> IO (Either Errno Nat)
  pread fd buf count offset =
    primIO (prim__pread fd.rawfd buf count offset) >>= checkCount


  %inline %foreign "CExpr:(pwrite($1, $2, $3, $4)),libc,unistd.h"
  prim__pwrite : Int32 -> Buffer -> Bits64 -> Bits64 -> PrimIO Int64

  ||| Write from a buffer at a specific file offset.
  %inline public export
  pwrite : FileDesc -> Buffer -> Bits64-> Bits64 -> IO (Either Errno Nat)
  pwrite fd buf count offset =
    primIO (prim__pwrite fd.rawfd buf count offset) >>= checkCount




