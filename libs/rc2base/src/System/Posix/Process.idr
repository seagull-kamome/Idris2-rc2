module System.Posix.Process

import Data.Buffer
import Data.String.FFI
import System.Posix.Errno
import System.Posix.Signal
import System.FFI
import System.FFI.C.Array

%default total

-------------------------------------------------------------------------------
--

||| A Unix process identifier.
public export data ProcessID = MkProcessID Int32
export
Cast Int32 ProcessID where cast x = MkProcessID x
export
Cast ProcessID Int32 where cast (MkProcessID x) = x
export
Show ProcessID where
  show (MkProcessID x) = "ProcessID " ++ show x

||| A Unix process group identifier.
public export data ProcessGroupID = MkProcessGroupID Int32
export
Cast Int32 ProcessGroupID where cast x = MkProcessGroupID x
export
Cast ProcessGroupID Int32 where cast (MkProcessGroupID x) = x
export
Show ProcessGroupID where
  show (MkProcessGroupID x) = "ProcessGroupID " ++ show x


||| The status returned by a process-related operation.
public export data ProcessStatus = MkProcessStatus Int32
export
Cast Int32 ProcessStatus where cast x = MkProcessStatus x
export
Cast ProcessStatus Int32 where cast (MkProcessStatus x) = x
export
Show ProcessStatus where
  show (MkProcessStatus x) = "ProcessStatus " ++ show x


-------------------------------------------------------------------------------
-- Process Control

%foreign "CExpr:(getpid()),libc,unistd.h"
prim__getpid : PrimIO Int32
||| Return the identifier of the current process.
%inline public export getpid : IO ProcessID
getpid = do
  pid <- primIO prim__getpid
  pure $ MkProcessID pid


%foreign "CExpr:(kill($1, $2)),libc,sys/types.h;unistd.h"
prim__kill : Int32 -> Int32 -> PrimIO Int32
||| Send a signal to a process (signal 0 only checks that the process exists).
%inline public export kill : ProcessID -> Signal -> IO (Either Errno ())
kill (MkProcessID pid) (MkSignal sig) = primIO (prim__kill pid sig) >>= checkUnit

%inline %foreign "CExpr:(sigqueue($1, $2, (union sigval){ .sival_int = ($3) })),libc,signal.h"
prim__sigqueue : Int32 -> Int32 -> Int32 -> PrimIO Int32

||| Send a signal with an integer value, which the receiver reads from
||| `siginfo` (`signalfd`). The queue is bounded: `Left EAGAIN`
||| when it is full.
export
sigqueue : ProcessID -> Signal -> (value : Int32) -> IO (Either Errno ())
sigqueue (MkProcessID pid) (MkSignal sig) v = primIO (prim__sigqueue pid sig v) >>= checkUnit


-- exit should'nt be implemented in Idris2, but we need it for the FFI.  It should be used with care.
%foreign "CExpr:(exit($1)),libc,stdlib.h"
prim__exit : Int32 -> PrimIO ()
||| Exit the current process with the given status code.
%inline public export exit : Int32 -> IO ()
exit code = primIO $ prim__exit code    

%foreign "CExpr:(fork()),libc,sys/types.h;unistd.h"
prim__fork : PrimIO Int32
||| Create a child process and return its process ID.
%inline public export fork : IO ProcessID
fork = do
  pid <- primIO prim__fork
  pure $ MkProcessID pid


-------------------------------------------------------------------------------
--

%inline %foreign "CExpr:(sizeof(char *)),libc,stdlib.h"
prim__sizeofPtr : Int
%inline %foreign "CExpr:(strlen($1) + 1),libc,string.h"
prim__strlen1 : String -> PrimIO Int
%inline %foreign "CExpr:(strcpy((char *)($1), $2)),libc,string.h"
prim__strcpy : AnyPtr -> String -> PrimIO AnyPtr
%inline %foreign "CExpr:(((char **)($1))[$2] = (char *)($3)),libc,stdlib.h"
prim__setArgvPtr : AnyPtr -> Int -> AnyPtr -> PrimIO AnyPtr
%inline %foreign "CExpr:(((char **)($1))[$2] = NULL),libc,stdlib.h"
prim__nullArgv : AnyPtr -> Int -> PrimIO AnyPtr
%inline %foreign "CExpr:(free(((char **)($1))[$2])),libc,stdlib.h"
prim__freeArgv : AnyPtr -> Int -> PrimIO ()

||| A NULL-terminated `char *` array copied from the strings; `freeArgv` with
||| the number of strings frees it.
export
newArgv : List String -> IO AnyPtr
newArgv xs = do
  p <- malloc ((cast (length xs) + 1) * prim__sizeofPtr)
  go p 0 xs
  _ <- primIO (prim__nullArgv p (cast (length xs)))
  pure p
  where
    go : AnyPtr -> Int -> List String -> IO ()
    go p i [] = pure ()
    go p i (x :: rest) = do
      n <- primIO (prim__strlen1 x)
      copy <- malloc n
      _ <- primIO (prim__strcpy copy x)
      _ <- primIO (prim__setArgvPtr p i copy)
      go p (i + 1) rest

export
freeArgv : Nat -> AnyPtr -> IO ()
freeArgv n p = do
  go n
  free p
  where
    go : Nat -> IO ()
    go Z = pure ()
    go (S k) = primIO (prim__freeArgv p (cast k)) >> go k

%inline %foreign "CExpr:(execv($1, (char *const *)($2))),libc,unistd.h"
prim__execv : String -> AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(execvp($1, (char *const *)($2))),libc,unistd.h"
prim__execvp : String -> AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(execve($1, (char *const *)($2), (char *const *)($3))),libc,unistd.h"
prim__execve : String -> AnyPtr -> AnyPtr -> PrimIO Int32

||| Replace the process image. `argv` includes the program name as its first
||| element (an empty `argv` passes no program name at all, which Linux accepts but
||| warns about). Returns only on failure, with the `errno`; on success it does not return.
export
execv : (path : String) -> (argv : List String) -> IO Errno
execv path argv = do
  a <- newArgv argv
  _ <- primIO (prim__execv path a)
  e <- errno
  freeArgv (length argv) a
  pure e

||| Like `execv`, but the program is looked up in `PATH` when `file` has no slash.
export
execvp : (file : String) -> (argv : List String) -> IO Errno
execvp file argv = do
  a <- newArgv argv
  _ <- primIO (prim__execvp file a)
  e <- errno
  freeArgv (length argv) a
  pure e

||| Like `execv`, with an explicit environment of `NAME=value` strings.
export
execve : (path : String) -> (argv : List String) -> (envp : List String) -> IO Errno
execve path argv envp = do
  a <- newArgv argv
  e <- newArgv envp
  _ <- primIO (prim__execve path a e)
  err <- errno
  freeArgv (length argv) a
  freeArgv (length envp) e
  pure err



-------------------------------------------------------------------------------
-- Wait - Process Control

%foreign "CExpr:(waitpid($1, (int *)$2, $3)),libc,sys/types.h;sys/wait.h;unistd.h"
prim__waitpid : Int32 -> AnyPtr -> Int32 -> PrimIO Int32
%foreign "CExpr:(*(int *)($1)),libc,sys/wait.h"
prim__intStatus : AnyPtr -> PrimIO Int32

||| Option bits for `waitpid`.
public export
WaitOptions : Type
WaitOptions = Int32

||| Wait for children that have terminated. A `waitid(2)` option: `waitpid` rejects it with `EINVAL`.
%inline %foreign "CExpr:(WEXITED),libc,sys/types.h;sys/wait.h;unistd.h"
export WEXITED : Int32
||| Wait for children stopped by a signal. A `waitid(2)` option: `waitpid` rejects it with `EINVAL`.
%inline %foreign "CExpr:(WSTOPPED),libc,sys/types.h;sys/wait.h;unistd.h"
export WSTOPPED : Int32
||| Return at once if no child has changed state.
%inline %foreign "CExpr:(WNOHANG),libc,sys/types.h;sys/wait.h;unistd.h"
export WNOHANG : Int32
||| Also report children that are stopped.
%inline %foreign "CExpr:(WUNTRACED),libc,sys/types.h;sys/wait.h;unistd.h"
export WUNTRACED : Int32
||| Also report stopped children that were continued by `SIGCONT`.
%inline %foreign "CExpr:(WCONTINUED),libc,sys/types.h;sys/wait.h;unistd.h"
export WCONTINUED : Int32


||| Shared body of `wait` and `waitpid`: `waitpid(2)` on the given pid and options.
wait_ : Int32 -> Int32 -> IO (Either Errno (ProcessID, ProcessStatus))
wait_ pid options = do
  buf <- malloc 4
  r <- primIO (prim__waitpid pid buf options)
  res <- if r < 0
            then Left <$> errno
            else do st <- primIO (prim__intStatus buf)
                    pure (Right (MkProcessID r, MkProcessStatus st))
  free buf
  pure res

||| Wait for a child process to change state; `Left ECHILD` when there is none,
||| `Left EINTR` when a signal interrupted the wait.
public export wait : IO (Either Errno (ProcessID, ProcessStatus))
wait = wait_ (-1) 0

||| Wait for a child process to change state. With `WNOHANG` and no child that
||| has changed state, the result has the process ID 0.
||| See also wait.
||| @pid@ is the process ID of the child to wait for, or -1 to wait for any child process.
||| @options@ is a bitmask of options that modify the behavior of waitpid.
public export waitpid : (pid : ProcessID) -> (options : Int32) -> IO (Either Errno (ProcessID, ProcessStatus))
waitpid (MkProcessID pid) options = wait_ pid options

||| Wait for a child process in the given process group to change state.
||| See also wait.
||| @pgrp@ is the process group ID whose children to wait for (it is negated for `waitpid`: pass the group's own ID, not -1).
||| @options@ is a bitmask of options that modify the behavior of waitpid.
public export waitpidGroup : (pgrp : ProcessGroupID) -> (options : Int32) -> IO (Either Errno (ProcessID, ProcessStatus))
waitpidGroup (MkProcessGroupID pgid) options = wait_ (-pgid) options


-------------------------------------------------------------------------------
-- Wait status

%inline %foreign "CExpr:(WIFEXITED($1)),libc,sys/wait.h"
prim__WIFEXITED : Int32 -> Int32
%inline %foreign "CExpr:(WEXITSTATUS($1)),libc,sys/wait.h"
prim__WEXITSTATUS : Int32 -> Int32
%inline %foreign "CExpr:(WIFSIGNALED($1)),libc,sys/wait.h"
prim__WIFSIGNALED : Int32 -> Int32
%inline %foreign "CExpr:(WTERMSIG($1)),libc,sys/wait.h"
prim__WTERMSIG : Int32 -> Int32
%inline %foreign "CExpr:(WIFSTOPPED($1)),libc,sys/wait.h"
prim__WIFSTOPPED : Int32 -> Int32
%inline %foreign "CExpr:(WSTOPSIG($1)),libc,sys/wait.h"
prim__WSTOPSIG : Int32 -> Int32

||| The exit code of a child that terminated normally.
export
exitedWith : ProcessStatus -> Maybe Int32
exitedWith (MkProcessStatus s) =
  if prim__WIFEXITED s /= 0 then Just (prim__WEXITSTATUS s) else Nothing

||| The signal that terminated a child.
export
killedBy : ProcessStatus -> Maybe Signal
killedBy (MkProcessStatus s) =
  if prim__WIFSIGNALED s /= 0 then Just (MkSignal (prim__WTERMSIG s)) else Nothing

||| The signal that stopped a child (reported with `WUNTRACED`).
export
stoppedBy : ProcessStatus -> Maybe Signal
stoppedBy (MkProcessStatus s) =
  if prim__WIFSTOPPED s /= 0 then Just (MkSignal (prim__WSTOPSIG s)) else Nothing

-------------------------------------------------------------------------------
-- Identities and process groups

%inline %foreign "CExpr:(getppid()),libc,unistd.h"
prim__getppid : PrimIO Int32
%inline %foreign "CExpr:(getuid()),libc,unistd.h"
prim__getuid : PrimIO Bits32
%inline %foreign "CExpr:(geteuid()),libc,unistd.h"
prim__geteuid : PrimIO Bits32
%inline %foreign "CExpr:(getgid()),libc,unistd.h"
prim__getgid : PrimIO Bits32
%inline %foreign "CExpr:(getegid()),libc,unistd.h"
prim__getegid : PrimIO Bits32
%inline %foreign "CExpr:(getpgrp()),libc,unistd.h"
prim__getpgrp : PrimIO Int32
%inline %foreign "CExpr:(getpgid($1)),libc,unistd.h"
prim__getpgid : Int32 -> PrimIO Int32
%inline %foreign "CExpr:(setpgid($1, $2)),libc,unistd.h"
prim__setpgid : Int32 -> Int32 -> PrimIO Int32
%inline %foreign "CExpr:(getsid($1)),libc,unistd.h"
prim__getsid : Int32 -> PrimIO Int32
%inline %foreign "CExpr:(setsid()),libc,unistd.h"
prim__setsid : PrimIO Int32

||| The parent's process ID.
export
getppid : IO ProcessID
getppid = MkProcessID <$> primIO prim__getppid

||| The real user ID.
export getuid : IO Bits32
getuid = primIO prim__getuid
||| The effective user ID.
export geteuid : IO Bits32
geteuid = primIO prim__geteuid
||| The real group ID.
export getgid : IO Bits32
getgid = primIO prim__getgid
||| The effective group ID.
export getegid : IO Bits32
getegid = primIO prim__getegid

||| The process group ID of the calling process.
export
getpgrp : IO ProcessGroupID
getpgrp = MkProcessGroupID <$> primIO prim__getpgrp

||| The process group ID of a process (`0` for the calling one).
export
getpgid : ProcessID -> IO (Either Errno ProcessGroupID)
getpgid (MkProcessID p) = do
  r <- primIO (prim__getpgid p)
  map (map MkProcessGroupID) (checkNonNeg r)

||| Put a process into a process group (`0` for the calling process and for "the same as the process").
export
setpgid : ProcessID -> ProcessGroupID -> IO (Either Errno ())
setpgid (MkProcessID p) (MkProcessGroupID g) = primIO (prim__setpgid p g) >>= checkUnit

||| The session ID of a process (`0` for the calling one).
export
getsid : ProcessID -> IO (Either Errno ProcessID)
getsid (MkProcessID p) = do
  r <- primIO (prim__getsid p)
  map (map MkProcessID) (checkNonNeg r)

||| Start a new session; the caller becomes its leader.
export
setsid : IO (Either Errno ProcessGroupID)
setsid = do
  r <- primIO prim__setsid
  map (map MkProcessGroupID) (checkNonNeg r)

-------------------------------------------------------------------------------
-- exit without cleanup / nice

%inline %foreign "CExpr:(_exit($1)),libc,unistd.h"
prim___exit : Int32 -> PrimIO ()

||| Terminate at once, without running `atexit` handlers or flushing C stdio
||| (`_exit`). Use it in a forked child that must not touch the parent's buffers.
export
exitNow : Int32 -> IO ()
exitNow code = primIO (prim___exit code)

%inline %foreign "CExpr:(errno = 0, nice($1)),libc,errno.h;unistd.h"
prim__nice : Int32 -> PrimIO Int32

||| Add to the niceness of the process; returns the new value. `nice` returns -1 on
||| success too, so a failure is told by `errno` (cleared before the call).
export
nice : Int32 -> IO (Either Errno Int32)
nice inc = do
  r <- primIO (prim__nice inc)
  e <- errno
  pure (if r == -1 && e /= MkErrno 0 then Left e else Right r)

-------------------------------------------------------------------------------
-- Resource limits

||| A resource for `getrlimit`/`setrlimit` (`RLIMIT_*`).
public export
data Resource = MkResource Int32

%inline %foreign "CExpr:(RLIMIT_CORE),libc,sys/resource.h"
prim__RLIMIT_CORE : Int32
%inline %foreign "CExpr:(RLIMIT_CPU),libc,sys/resource.h"
prim__RLIMIT_CPU : Int32
%inline %foreign "CExpr:(RLIMIT_DATA),libc,sys/resource.h"
prim__RLIMIT_DATA : Int32
%inline %foreign "CExpr:(RLIMIT_FSIZE),libc,sys/resource.h"
prim__RLIMIT_FSIZE : Int32
%inline %foreign "CExpr:(RLIMIT_NOFILE),libc,sys/resource.h"
prim__RLIMIT_NOFILE : Int32
%inline %foreign "CExpr:(RLIMIT_STACK),libc,sys/resource.h"
prim__RLIMIT_STACK : Int32
%inline %foreign "CExpr:(RLIMIT_AS),libc,sys/resource.h"
prim__RLIMIT_AS : Int32

||| Largest core file.
export RLIMIT_CORE : Resource
RLIMIT_CORE = MkResource prim__RLIMIT_CORE
||| CPU time in seconds.
export RLIMIT_CPU : Resource
RLIMIT_CPU = MkResource prim__RLIMIT_CPU
||| Size of the data segment.
export RLIMIT_DATA : Resource
RLIMIT_DATA = MkResource prim__RLIMIT_DATA
||| Largest file the process may create.
export RLIMIT_FSIZE : Resource
RLIMIT_FSIZE = MkResource prim__RLIMIT_FSIZE
||| One more than the highest file descriptor number.
export RLIMIT_NOFILE : Resource
RLIMIT_NOFILE = MkResource prim__RLIMIT_NOFILE
||| Size of the stack.
export RLIMIT_STACK : Resource
RLIMIT_STACK = MkResource prim__RLIMIT_STACK
||| Size of the address space.
export RLIMIT_AS : Resource
RLIMIT_AS = MkResource prim__RLIMIT_AS

%inline %foreign "CExpr:(RLIM_INFINITY),libc,sys/resource.h"
prim__RLIM_INFINITY : Bits64

||| The value of a limit that means "no limit".
export RLIM_INFINITY : Bits64
RLIM_INFINITY = prim__RLIM_INFINITY

||| A soft and a hard limit.
public export
record Rlimit where
  constructor MkRlimit
  soft : Bits64
  hard : Bits64

export
Show Rlimit where
  show l = "Rlimit " ++ show l.soft ++ " " ++ show l.hard

export
Eq Rlimit where
  a == b = a.soft == b.soft && a.hard == b.hard

%inline %foreign "CExpr:(sizeof(struct rlimit)),libc,sys/resource.h"
prim__sizeofRlimit : Int
%inline %foreign "CExpr:(getrlimit($1, (struct rlimit *)($2))),libc,sys/resource.h"
prim__getrlimit : Int32 -> AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(setrlimit($1, (struct rlimit *)($2))),libc,sys/resource.h"
prim__setrlimit : Int32 -> AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(((struct rlimit *)($1))->rlim_cur),libc,sys/resource.h"
prim__get_rlim_cur : AnyPtr -> PrimIO Bits64
%inline %foreign "CExpr:(((struct rlimit *)($1))->rlim_max),libc,sys/resource.h"
prim__get_rlim_max : AnyPtr -> PrimIO Bits64
%inline %foreign "CExpr:(((struct rlimit *)($1))->rlim_cur = ($2)),libc,sys/resource.h"
prim__set_rlim_cur : AnyPtr -> Bits64 -> PrimIO Bits64
%inline %foreign "CExpr:(((struct rlimit *)($1))->rlim_max = ($2)),libc,sys/resource.h"
prim__set_rlim_max : AnyPtr -> Bits64 -> PrimIO Bits64

||| The soft and hard limit of a resource.
export
getrlimit : Resource -> IO (Either Errno Rlimit)
getrlimit (MkResource r) = do
  p <- malloc prim__sizeofRlimit
  rc <- primIO (prim__getrlimit r p)
  res <- if rc == 0
            then do c <- primIO (prim__get_rlim_cur p)
                    m <- primIO (prim__get_rlim_max p)
                    pure (Right (MkRlimit c m))
            else Left <$> errno
  free p
  pure res

||| Set the soft and hard limit of a resource.
export
setrlimit : Resource -> Rlimit -> IO (Either Errno ())
setrlimit (MkResource r) l = do
  p <- malloc prim__sizeofRlimit
  _ <- primIO (prim__set_rlim_cur p l.soft)
  _ <- primIO (prim__set_rlim_max p l.hard)
  rc <- primIO (prim__setrlimit r p)
  res <- checkUnit rc
  free p
  pure res

-------------------------------------------------------------------------------
-- uname / gethostname / sysconf

||| The fields of `struct utsname`.
public export
record Utsname where
  constructor MkUtsname
  sysname : String
  nodename : String
  release : String
  version : String
  machine : String

export
Show Utsname where
  show u = "Utsname " ++ show u.sysname ++ " " ++ show u.nodename ++ " " ++ show u.release
        ++ " " ++ show u.version ++ " " ++ show u.machine

%inline %foreign "CExpr:(sizeof(struct utsname)),libc,sys/utsname.h"
prim__sizeofUtsname : Int
%inline %foreign "CExpr:(uname((struct utsname *)($1))),libc,sys/utsname.h"
prim__uname : AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(((struct utsname *)($1))->sysname),libc,sys/utsname.h"
prim__u_sysname : AnyPtr -> PrimIO String
%inline %foreign "CExpr:(((struct utsname *)($1))->nodename),libc,sys/utsname.h"
prim__u_nodename : AnyPtr -> PrimIO String
%inline %foreign "CExpr:(((struct utsname *)($1))->release),libc,sys/utsname.h"
prim__u_release : AnyPtr -> PrimIO String
%inline %foreign "CExpr:(((struct utsname *)($1))->version),libc,sys/utsname.h"
prim__u_version : AnyPtr -> PrimIO String
%inline %foreign "CExpr:(((struct utsname *)($1))->machine),libc,sys/utsname.h"
prim__u_machine : AnyPtr -> PrimIO String

||| Name and version of the system.
export
uname : IO (Either Errno Utsname)
uname = do
  p <- malloc prim__sizeofUtsname
  rc <- primIO (prim__uname p)
  res <- if rc == 0
            then do a <- primIO (prim__u_sysname p)
                    b <- primIO (prim__u_nodename p)
                    c <- primIO (prim__u_release p)
                    d <- primIO (prim__u_version p)
                    e <- primIO (prim__u_machine p)
                    pure (Right (MkUtsname a b c d e))
            else Left <$> errno
  free p
  pure res

%inline %foreign "CExpr:(((char *)($1))[$2] = 0),libc,stdlib.h"
prim__terminate : AnyPtr -> Int -> PrimIO Int32
%inline %foreign "CExpr:(gethostname((char *)($1), $2)),libc,unistd.h"
prim__gethostname : AnyPtr -> Bits64 -> PrimIO Int32

||| The host name.
export
gethostname : IO (Either Errno String)
gethostname = do
  buf <- malloc 1024
  rc <- primIO (prim__gethostname buf 1023)
  if rc /= 0
     then do e <- errno
             free buf
             pure (Left e)
     else do
       _ <- primIO (prim__terminate buf 1023)
       s <- ptrToStringFree buf
       pure (maybe (Left (MkErrno 84)) Right s)

||| A name for `sysconf` (`SC_*` stands for C's `_SC_*`).
public export
data SysconfName = MkSysconfName Int32

%inline %foreign "CExpr:(_SC_ARG_MAX),libc,unistd.h"
prim__SC_ARG_MAX : Int32
%inline %foreign "CExpr:(_SC_CLK_TCK),libc,unistd.h"
prim__SC_CLK_TCK : Int32
%inline %foreign "CExpr:(_SC_OPEN_MAX),libc,unistd.h"
prim__SC_OPEN_MAX : Int32
%inline %foreign "CExpr:(_SC_PAGESIZE),libc,unistd.h"
prim__SC_PAGESIZE : Int32
%inline %foreign "CExpr:(_SC_NPROCESSORS_ONLN),libc,unistd.h"
prim__SC_NPROCESSORS_ONLN : Int32

||| Maximum length of the arguments of `exec` plus the environment.
export SC_ARG_MAX : SysconfName
SC_ARG_MAX = MkSysconfName prim__SC_ARG_MAX
||| Clock ticks per second.
export SC_CLK_TCK : SysconfName
SC_CLK_TCK = MkSysconfName prim__SC_CLK_TCK
||| Maximum number of open files per process.
export SC_OPEN_MAX : SysconfName
SC_OPEN_MAX = MkSysconfName prim__SC_OPEN_MAX
||| The size of a page in bytes.
export SC_PAGESIZE : SysconfName
SC_PAGESIZE = MkSysconfName prim__SC_PAGESIZE
||| Number of processors currently online.
|||
||| Not in POSIX; Linux and BSD.
export SC_NPROCESSORS_ONLN : SysconfName
SC_NPROCESSORS_ONLN = MkSysconfName prim__SC_NPROCESSORS_ONLN

%inline %foreign "CExpr:(sysconf($1)),libc,unistd.h"
prim__sysconf : Int32 -> PrimIO Int64

||| A system configuration value; `Nothing` when the name is unsupported or the limit is indeterminate.
export
sysconf : SysconfName -> IO (Maybe Int64)
sysconf (MkSysconfName n) = do
  r <- primIO (prim__sysconf n)
  pure (if r < 0 then Nothing else Just r)
