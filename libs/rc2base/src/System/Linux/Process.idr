||| Linux's thread and process interfaces: `gettid`, process file descriptors
||| (`pidfd_open`, `pidfd_send_signal`), the CPU a thread runs on and its CPU
||| affinity.
|||
||| Linux only. `sched_getcpu`, the affinity calls and `cpu_set_t` are declared by
||| glibc only under `_GNU_SOURCE`: build with `IDRIS2_CFLAGS=-D_GNU_SOURCE`. The pidfd calls go through
||| `syscall(2)` (they need Linux 5.3; 5.1 for `pidfd_send_signal`), so a kernel
||| without them gives `Left ENOSYS`.
module System.Linux.Process

import System.FFI
import System.Posix.Errno
import System.Posix.FileDesc
import System.Posix.Process
import System.Posix.Signal

%default total

%inline %foreign "CExpr:(syscall(SYS_gettid)),libc,unistd.h;sys/syscall.h"
prim__gettid : PrimIO Int32
%inline %foreign "CExpr:(syscall(SYS_pidfd_open, (long)($1), (long)($2))),libc,unistd.h;sys/syscall.h"
prim__pidfd_open : Int32 -> Bits32 -> PrimIO Int32
%inline %foreign "CExpr:(syscall(SYS_pidfd_send_signal, (long)($1), (long)($2), 0L, 0L)),libc,unistd.h;sys/syscall.h"
prim__pidfd_send_signal : Int32 -> Int32 -> PrimIO Int32
%inline %foreign "CExpr:(sched_getcpu()),libc,sched.h"
prim__sched_getcpu : PrimIO Int32
%inline %foreign "CExpr:(sizeof(cpu_set_t)),libc,sched.h"
prim__sizeofCpuSet : Int
%inline %foreign "CExpr:(CPU_SETSIZE),libc,sched.h"
prim__CPU_SETSIZE : Int
%inline %foreign "CExpr:(({ CPU_ZERO((cpu_set_t *)($1)); 0; })),libc,sched.h"
prim__cpu_zero : AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(({ CPU_SET($1, (cpu_set_t *)($2)); 0; })),libc,sched.h"
prim__cpu_set : Int -> AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(CPU_ISSET($1, (cpu_set_t *)($2))),libc,sched.h"
prim__cpu_isset : Int -> AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(sched_getaffinity($1, sizeof(cpu_set_t), (cpu_set_t *)($2))),libc,sched.h"
prim__sched_getaffinity : Int32 -> AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(sched_setaffinity($1, sizeof(cpu_set_t), (cpu_set_t *)($2))),libc,sched.h"
prim__sched_setaffinity : Int32 -> AnyPtr -> PrimIO Int32

||| The kernel's ID of the calling thread. In the main thread it is the process ID.
export
gettid : IO ProcessID
gettid = MkProcessID <$> primIO prim__gettid

||| A file descriptor for a process. It can be waited on with `poll` (readable
||| once the process has exited) and survives the reuse of the process ID.
||| `flags` is 0 or `O_NONBLOCK` (Linux 5.10, for `waitid` on it).
export
pidfd_open : ProcessID -> (flags : Bits32) -> IO (Either Errno FileDesc)
pidfd_open (MkProcessID pid) flags = primIO (prim__pidfd_open pid flags) >>= primFdToFileDesc

||| Send a signal to the process of a pidfd, which cannot be a different
||| process by now.
export
pidfd_send_signal : FileDesc -> Signal -> IO (Either Errno ())
pidfd_send_signal fd (MkSignal sig) = primIO (prim__pidfd_send_signal fd.rawfd sig) >>= checkUnit

||| The number of the CPU the calling thread is running on now.
export
sched_getcpu : IO (Either Errno Int32)
sched_getcpu = primIO prim__sched_getcpu >>= checkNonNeg

-- `Nothing` is the calling thread (ID 0).
tidOf : Maybe ProcessID -> Int32
tidOf Nothing = 0
tidOf (Just (MkProcessID n)) = n

||| The CPUs a thread may run on, in ascending order (the calling thread for
||| `Nothing`). The set holds `CPU_SETSIZE` (1024) CPUs; on a machine with more
||| possible CPUs the kernel refuses with `EINVAL`.
export
getAffinity : Maybe ProcessID -> IO (Either Errno (List Int))
getAffinity pid = do
  set <- malloc prim__sizeofCpuSet
  r <- primIO (prim__sched_getaffinity (tidOf pid) set)
  res <- if r == 0 then Right <$> members set (cast prim__CPU_SETSIZE) [] else Left <$> errno
  free set
  pure res
  where
    -- From the highest CPU down, so that prepending leaves the list ascending.
    members : AnyPtr -> Nat -> List Int -> IO (List Int)
    members set Z acc = pure acc
    members set (S k) acc = do
      b <- primIO (prim__cpu_isset (cast k) set)
      members set k (if b /= 0 then cast k :: acc else acc)

||| Restrict the CPUs a thread may run on (the calling thread for `Nothing`). A
||| number outside `0 .. CPU_SETSIZE - 1` is ignored, so a list with none inside
||| is an empty set, which the kernel refuses with `EINVAL`.
export
setAffinity : Maybe ProcessID -> List Int -> IO (Either Errno ())
setAffinity pid cpus = do
  set <- malloc prim__sizeofCpuSet
  _ <- primIO (prim__cpu_zero set)
  traverse_ (\c => if c >= 0 && c < prim__CPU_SETSIZE then ignore (primIO (prim__cpu_set c set)) else pure ()) cpus
  r <- primIO (prim__sched_setaffinity (tidOf pid) set)
  res <- checkUnit r
  free set
  pure res
