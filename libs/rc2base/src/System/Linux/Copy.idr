||| Copying data between descriptors inside the kernel: `sendfile`, `splice`
||| and `copy_file_range`.
|||
||| Linux only. `splice` and `copy_file_range` are declared by glibc only under
||| `_GNU_SOURCE`: build with `IDRIS2_CFLAGS=-D_GNU_SOURCE`. Written for a 64-bit
||| system, where `off_t` and `size_t` are 64 bits.
||| An offset of `Just o` reads or writes at `o` and leaves the descriptor's own
||| position alone; `Nothing` uses (and moves) that position.
module System.Linux.Copy

import System.FFI
import System.Posix.Errno
import System.Posix.FileDesc

%default total

||| An `or` of `SPLICE_F_*` bits.
public export
SpliceFlags : Type
SpliceFlags = Bits32

||| Try to move pages instead of copying them (a hint). Needs `_GNU_SOURCE`.
%inline %foreign "CExpr:(SPLICE_F_MOVE),libc,fcntl.h"
export SPLICE_F_MOVE : SpliceFlags
||| Do not block on the pipe (the other descriptor may still block). Needs `_GNU_SOURCE`.
%inline %foreign "CExpr:(SPLICE_F_NONBLOCK),libc,fcntl.h"
export SPLICE_F_NONBLOCK : SpliceFlags
||| More data will follow (a hint, for a socket). Needs `_GNU_SOURCE`.
%inline %foreign "CExpr:(SPLICE_F_MORE),libc,fcntl.h"
export SPLICE_F_MORE : SpliceFlags

%inline %foreign "CExpr:((void *)NULL),libc,stddef.h"
prim__nullPtr : AnyPtr
%inline %foreign "CExpr:(*(int64_t *)($1) = ($2)),libc,stdint.h"
prim__setI64 : AnyPtr -> Int64 -> PrimIO Int64
%inline %foreign "CExpr:(sendfile($1, $2, (off_t *)($3), $4)),libc,sys/sendfile.h"
prim__sendfile : Int32 -> Int32 -> AnyPtr -> Bits64 -> PrimIO Int64
%inline %foreign "CExpr:(splice($1, (off64_t *)($2), $3, (off64_t *)($4), $5, $6)),libc,fcntl.h"
prim__splice : Int32 -> AnyPtr -> Int32 -> AnyPtr -> Bits64 -> SpliceFlags -> PrimIO Int64
%inline %foreign "CExpr:(copy_file_range($1, (off64_t *)($2), $3, (off64_t *)($4), $5, 0)),libc,unistd.h"
prim__copy_file_range : Int32 -> AnyPtr -> Int32 -> AnyPtr -> Bits64 -> PrimIO Int64

-- The offsets are passed by address, so a `Just` needs a cell for the call.
withOffset : Maybe Int64 -> (AnyPtr -> IO (Either Errno Int64)) -> IO (Either Errno Int64)
withOffset Nothing k = k prim__nullPtr
withOffset (Just o) k = do
  p <- malloc 8
  _ <- primIO (prim__setI64 p o)
  r <- k p
  free p
  pure r

-- Reads `errno` before the cell is freed.
bytes : Int64 -> IO (Either Errno Int64)
bytes n = if n < 0 then Left <$> errno else pure (Right n)

||| Copy up to `count` bytes from `inp` (which must be a file that can be
||| mapped) to `out`. Returns the number of bytes copied.
export
sendfile : (out : FileDesc) -> (inp : FileDesc) -> (offset : Maybe Int64) -> (count : Bits64)
        -> IO (Either Errno Int64)
sendfile out inp offset count =
  withOffset offset $ \p => primIO (prim__sendfile out.rawfd inp.rawfd p count) >>= bytes

||| Move up to `len` bytes between two descriptors, one of which is a pipe (the
||| offset of the pipe end must be `Nothing`). Returns the number of bytes moved;
||| 0 at the end of the input.
export
splice : (inp : FileDesc) -> (inOffset : Maybe Int64) -> (out : FileDesc) -> (outOffset : Maybe Int64)
      -> (len : Bits64) -> SpliceFlags -> IO (Either Errno Int64)
splice inp inOff out outOff len flags =
  withOffset inOff $ \pi => withOffset outOff $ \po =>
    primIO (prim__splice inp.rawfd pi out.rawfd po len flags) >>= bytes

||| Copy up to `len` bytes between two regular files, in the kernel (and without
||| copying at all on a file system that can share the blocks). Returns the
||| number of bytes copied; 0 at the end of the input.
export
copy_file_range : (inp : FileDesc) -> (inOffset : Maybe Int64) -> (out : FileDesc) -> (outOffset : Maybe Int64)
               -> (len : Bits64) -> IO (Either Errno Int64)
copy_file_range inp inOff out outOff len =
  withOffset inOff $ \pi => withOffset outOff $ \po =>
    primIO (prim__copy_file_range inp.rawfd pi out.rawfd po len) >>= bytes
