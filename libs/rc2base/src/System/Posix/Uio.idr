module System.Posix.Uio

import Data.Buffer
import Data.Buffer.RC2
import Data.String
import Data.String.RC2
import public System.Posix.FileDesc
import System.FFI
import System.FFI.C.Ptr

-------------------------------------------------------------------------------
-- 

||| A POSIX `struct iovec` describing a byte range for vector I/O.
public export
IOVec : Type
IOVec = Struct "unistd_iovec" [("iov_base", AnyPtr), ("iov_len", Bits64)]

%inline %foreign "CExpr:(sizeof(struct iovec)),libc,sys/uio.h"
export SizeOfIOVec : Bits64

%inline %foreign "CExpr:(readv($1, (const struct iovec*)$2, $3)),libc,sys/uio.h"
prim__readv : Bits32 -> IOVec -> Bits32 -> PrimIO Int64
%inline %foreign "CExpr:(writev($1, (const struct iovec*)$2, $3)),libc,sys/uio.h"
prim__writev : Bits32 -> IOVec -> Bits32 -> PrimIO Int64
%inline %foreign "CExpr:(preadv($1, (const struct iovec*)$2, $3, $4)),libc,sys/uio.h"
prim__preadv : Bits32 -> IOVec -> Bits32 -> Bits64 -> PrimIO Int64
%inline %foreign "CExpr:(pwritev($1, (const struct iovec*)$2, $3, $4)),libc,sys/uio.h"
prim__pwritev : Bits32 -> IOVec -> Bits32 -> Bits64 -> PrimIO Int64
%inline %foreign "CExpr:(preadv2($1, (const struct iovec*)$2, $3, $4, $5)),libc,sys/uio.h"
prim__preadv2 : Bits32 -> IOVec -> Bits32 -> Bits64 -> Bits32 -> PrimIO Int64
%inline %foreign "CExpr:(pwritev2($1, (const struct iovec*)$2, $3, $4, $5)),libc,sys/uio.h"
prim__pwritev2 : Bits32 -> IOVec -> Bits32 -> Bits64 -> Bits32 -> PrimIO Int64


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
readv : FileDesc -> List (AnyPtr, Bits64) -> IO Int64
readv fd xs = do
  let n : Bits32 := cast {to=Bits32} $ length xs
  iovec <- toIOVec xs
  ret <- primIO $ prim__readv fd.rawfd iovec n
  free $ believe_me iovec
  pure ret

||| Write data from a list of memory buffers to a file descriptor.
public export
writev : FileDesc -> List (AnyPtr, Bits64) -> IO Int64
writev fd xs = do
  let n : Bits32 := cast {to=Bits32} $ length xs
  iovec <- toIOVec xs
  ret <- primIO $ prim__writev fd.rawfd iovec n
  free $ believe_me iovec
  pure ret



-------------------------------------------------------------------------------
--  pread/pwrite


namespace AnyPtr
  %inline %foreign "CExpr:(pread($1, $2, $3, $4)),libc,unistd.h"
  prim__pread : Bits32 -> AnyPtr -> Bits64 -> Bits64 -> PrimIO Int64

  ||| Read from an arbitrary memory pointer at a specific offset.
  %inline public export
  pread : FileDesc -> AnyPtr -> Bits64-> Bits64 -> IO Int64
  pread fd buf count offset =
    primIO $ prim__pread fd.rawfd buf count offset


  %inline %foreign "CExpr:(pwrite($1, $2, $3, $4)),libc,unistd.h"
  prim__pwrite : Bits32 -> AnyPtr -> Bits64 -> Bits64 -> PrimIO Int64

  ||| Write to an arbitrary memory pointer at a specific offset.
  %inline public export
  pwrite : FileDesc -> AnyPtr -> Bits64-> Bits64 -> IO Int64
  pwrite fd buf count offset =
    primIO $ prim__pwrite fd.rawfd buf count offset


namespace Buffer
  %inline %foreign "CExpr:(pread($1, $2, $3, $4)),libc,unistd.h"
  prim__pread : Bits32 -> Buffer -> Bits64 -> Bits64 -> PrimIO Int64

  ||| Read from a buffer at a specific file offset.
  %inline public export
  pread : FileDesc -> Buffer -> Bits64-> Bits64 -> IO Int64
  pread fd buf count offset =
    primIO $ prim__pread fd.rawfd buf count offset


  %inline %foreign "CExpr:(pwrite($1, $2, $3, $4)),libc,unistd.h"
  prim__pwrite : Bits32 -> Buffer -> Bits64 -> Bits64 -> PrimIO Int64

  ||| Write from a buffer at a specific file offset.
  %inline public export
  pwrite : FileDesc -> Buffer -> Bits64-> Bits64 -> IO Int64
  pwrite fd buf count offset =
    primIO $ prim__pwrite fd.rawfd buf count offset




