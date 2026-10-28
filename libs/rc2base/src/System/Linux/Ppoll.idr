||| `ppoll`: `poll` with a time in nanoseconds and a signal mask for the time
||| of the wait.
|||
||| Linux and BSD, not in POSIX. glibc declares `ppoll` only under
||| `_GNU_SOURCE`: build the program with `IDRIS2_CFLAGS=-D_GNU_SOURCE`
||| (see "Build flags" in `System.Posix.File`).
module System.Linux.Ppoll

import System.FFI
import System.Posix.Errno
import System.Posix.FileDesc
import System.Posix.Poll
import System.Posix.Signal
import System.Posix.Time

%default total

%inline %foreign "CExpr:(ppoll((struct pollfd *)($1), $2, (const struct timespec *)($3), (const sigset_t *)($4))),libc,poll.h;signal.h;time.h"
prim__ppollMasked : AnyPtr -> Bits64 -> AnyPtr -> GCPtr RawSigSet -> PrimIO Int32
%inline %foreign "CExpr:(ppoll((struct pollfd *)($1), $2, (const struct timespec *)($3), NULL)),libc,poll.h;stddef.h;time.h"
prim__ppoll : AnyPtr -> Bits64 -> AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:((void *)NULL),libc,stddef.h"
prim__nullPtr : AnyPtr

||| `poll` that sets the signal mask for the time of the wait and restores it
||| after, in one step: a signal that arrives between a check of a flag and the
||| wait cannot be missed, if it is blocked outside and unblocked by the mask
||| given here. `Nothing` for the time is forever, `Nothing` for the mask is
||| to leave it as it is (then it is `poll` with a time of nanoseconds).
export
ppoll : List (FileDesc, PollEvents) -> (timeout : Maybe TimeSpec) -> (mask : Maybe SigSet)
     -> IO (Either Errno (List PollEvents))
ppoll fds timeout mask = withPollfds fds $ \p, n =>
  case timeout of
    Nothing => call p n prim__nullPtr
    Just t => withTimeSpec $ \tp => writeTimeSpec tp t >> call p n tp
  where
    call : AnyPtr -> Bits64 -> AnyPtr -> IO Int32
    call p n tp = primIO (maybe (prim__ppoll p n tp) (prim__ppollMasked p n tp) mask)
