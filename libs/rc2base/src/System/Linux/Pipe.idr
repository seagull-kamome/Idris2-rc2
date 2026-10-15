||| `pipe2`: a pipe with `O_CLOEXEC` / `O_NONBLOCK` set atomically.
|||
||| Linux and BSD, not in POSIX. glibc declares `pipe2` only under
||| `_GNU_SOURCE`: build the program with `IDRIS2_CFLAGS=-D_GNU_SOURCE`
||| (see "Build flags" in `System.Posix.File`).
module System.Linux.Pipe

import System.FFI
import System.Posix.Errno
import System.Posix.Fcntl
import System.Posix.FileDesc

%default total

%inline %foreign "CExpr:(pipe2((int *)($1), $2)),libc,fcntl.h;unistd.h"
prim__pipe2 : AnyPtr -> Bits32 -> PrimIO Int32

||| Create a pipe with the given `O_*` flags (`O_CLOEXEC`, `O_NONBLOCK`, `O_DIRECT`);
||| returns the read end and the write end.
export
pipe2 : (flags : Bits32) -> IO (Either Errno (FileDesc, FileDesc))
pipe2 flags = withFdPair (\p => prim__pipe2 p flags)
