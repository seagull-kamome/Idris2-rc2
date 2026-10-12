module System.Posix.Process

import Data.Buffer
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
||| Send a signal to a process.
%inline public export kill : ProcessID -> Signal -> IO Int32
kill (MkProcessID pid) (MkSignal sig) = primIO $ prim__kill pid sig


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

-- %foreign "CExpr:(execve($1, $2)),libc,unistd.h"
-- prim__execve : String -> AnyPtr -> AnyPtr -> PrimIO Int32



-------------------------------------------------------------------------------
-- Wait - Process Control

%foreign "CExpr:(waitpid($1, (int *)$2, $3)),libc,sys/types.h;sys/wait.h;unistd.h"
prim__waitpid : Int32 -> Buffer -> Int32 -> PrimIO Int32

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
wait_ : Int32 -> Int32 -> IO (Maybe (ProcessID, ProcessStatus))
wait_ pid options = do
  Just buf <- newBuffer 4
    | Nothing => pure Nothing
  pid <- primIO $ prim__waitpid pid buf options
  status <- getInt32 buf 0
  pure $ Just (MkProcessID pid, MkProcessStatus status)  



||| Wait for a child process to change state.
||| Return Nothing when run-out of memory,
|||  or ProcessID and ProcessStatus when successful.
public export wait : IO (Maybe (ProcessID, ProcessStatus))
wait = wait_ (-1) 0

||| Wait for a child process to change state.
||| See also wait.
||| @pid@ is the process ID of the child to wait for, or -1 to wait for any child process.
||| @options@ is a bitmask of options that modify the behavior of waitpid.
public export waitpid : (pid : ProcessID) -> (options : Int32) -> IO (Maybe (ProcessID, ProcessStatus))
waitpid (MkProcessID pid) options = wait_ pid options

||| Wait for a child process in the given process group to change state.
||| See also wait.
||| @pgrp@ is the process group ID of the child to wait for, or -1 to wait for any child process.
||| @options@ is a bitmask of options that modify the behavior of waitpid.
public export waitpidGroup : (pgrp : ProcessGroupID) -> (options : Int32) -> IO (Maybe (ProcessID, ProcessStatus))
waitpidGroup (MkProcessGroupID pgid) options = wait_ (-pgid) options

