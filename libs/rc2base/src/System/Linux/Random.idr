||| `getrandom`: random bytes from the kernel, without opening `/dev/urandom`.
|||
||| Linux only. `GRND_*` and `getrandom` are declared by glibc in `<sys/random.h>`.
module System.Linux.Random

import Data.Buffer
import System.FFI
import System.Posix.Errno

%default total

||| An `or` of `GRND_*` bits.
public export
RandomFlags : Type
RandomFlags = Bits32

||| Fail with `EAGAIN` instead of blocking while the kernel has not collected
||| enough entropy yet (only early in the boot).
%inline %foreign "CExpr:(GRND_NONBLOCK),libc,sys/random.h"
export GRND_NONBLOCK : RandomFlags
||| Draw from the `/dev/random` pool instead of the `/dev/urandom` pool. Linux
||| before 5.6 may block.
%inline %foreign "CExpr:(GRND_RANDOM),libc,sys/random.h"
export GRND_RANDOM : RandomFlags
||| Do not block, and return what there is even before the pool is ready:
||| random, but not necessarily secure (Linux 5.6; not with `GRND_RANDOM`, which
||| gives `EINVAL`).
%inline %foreign "CExpr:(GRND_INSECURE),libc,sys/random.h"
export GRND_INSECURE : RandomFlags

%inline %foreign "CExpr:(getrandom($1, $2, $3)),libc,sys/random.h"
prim__getrandom : Buffer -> Bits64 -> RandomFlags -> PrimIO Int64
%inline %foreign "CExpr:(getrandom($1, 8, $2)),libc,sys/random.h"
prim__getrandom8 : AnyPtr -> RandomFlags -> PrimIO Int64
%inline %foreign "CExpr:(*(uint64_t *)($1)),libc,stdint.h"
prim__u64At : AnyPtr -> PrimIO Bits64

||| Fill a buffer with random bytes. Returns the number of bytes written, which
||| is all of them without flags for a buffer of at most 256 bytes; with
||| `GRND_RANDOM` or `GRND_NONBLOCK`, for a larger buffer (one call gives at most
||| 2^25 - 1 bytes) or after a signal it can be fewer, so check it.
export
getrandom : Buffer -> RandomFlags -> IO (Either Errno Int64)
getrandom buf flags = do
  size <- rawSize buf
  n <- primIO (prim__getrandom buf (cast size) flags)
  if n < 0 then Left <$> errno else pure (Right n)

||| A random 64-bit number; `Left EIO` if the kernel gave fewer than 8 bytes.
export
getrandomBits64 : RandomFlags -> IO (Either Errno Bits64)
getrandomBits64 flags = do
  p <- malloc 8
  n <- primIO (prim__getrandom8 p flags)
  res <- if n < 0 then Left <$> errno
         else if n /= 8 then pure (Left EIO)
         else Right <$> primIO (prim__u64At p)
  free p
  pure res
