||| `prctl`: attributes of the calling process (or thread) that only Linux has.
|||
||| Linux only.
module System.Linux.Prctl

import Data.String.FFI
import System.FFI
import System.Posix.Errno
import System.Posix.Signal

%default total

%inline %foreign "CExpr:(prctl(PR_SET_NAME, (unsigned long)($1), 0UL, 0UL, 0UL)),libc,sys/prctl.h"
prim__set_name : String -> PrimIO Int32
%inline %foreign "CExpr:(prctl(PR_GET_NAME, (unsigned long)($1), 0UL, 0UL, 0UL)),libc,sys/prctl.h"
prim__get_name : AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(prctl(PR_SET_PDEATHSIG, (unsigned long)($1), 0UL, 0UL, 0UL)),libc,sys/prctl.h"
prim__set_pdeathsig : Int32 -> PrimIO Int32
%inline %foreign "CExpr:(prctl(PR_GET_PDEATHSIG, (unsigned long)($1), 0UL, 0UL, 0UL)),libc,sys/prctl.h"
prim__get_pdeathsig : AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(prctl(PR_SET_DUMPABLE, (unsigned long)($1), 0UL, 0UL, 0UL)),libc,sys/prctl.h"
prim__set_dumpable : Int32 -> PrimIO Int32
%inline %foreign "CExpr:(prctl(PR_GET_DUMPABLE, 0, 0UL, 0UL, 0UL)),libc,sys/prctl.h"
prim__get_dumpable : PrimIO Int32
%inline %foreign "CExpr:(prctl(PR_SET_CHILD_SUBREAPER, (unsigned long)($1), 0UL, 0UL, 0UL)),libc,sys/prctl.h"
prim__set_subreaper : Int32 -> PrimIO Int32
%inline %foreign "CExpr:(prctl(PR_GET_CHILD_SUBREAPER, (unsigned long)($1), 0UL, 0UL, 0UL)),libc,sys/prctl.h"
prim__get_subreaper : AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(prctl(PR_SET_NO_NEW_PRIVS, 1UL, 0UL, 0UL, 0UL)),libc,sys/prctl.h"
prim__set_no_new_privs : PrimIO Int32
%inline %foreign "CExpr:(prctl(PR_GET_NO_NEW_PRIVS, 0, 0UL, 0UL, 0UL)),libc,sys/prctl.h"
prim__get_no_new_privs : PrimIO Int32
%inline %foreign "CExpr:(*(int *)($1)),libc,stdlib.h"
prim__intAt : AnyPtr -> PrimIO Int32

toInt : Bool -> Int32
toInt b = if b then 1 else 0

-- An `int` result through a cell the call fills in.
outInt : (AnyPtr -> PrimIO Int32) -> IO (Either Errno Int32)
outInt call = do
  p <- malloc 4
  r <- primIO (call p)
  res <- if r == 0 then Right <$> primIO (prim__intAt p) else Left <$> errno
  free p
  pure res

||| Set the name of the calling thread (what `top` and `ps -L` show); a name
||| longer than 15 bytes is cut.
export
setThreadName : String -> IO (Either Errno ())
setThreadName name = primIO (prim__set_name name) >>= checkUnit

||| The name of the calling thread.
export
getThreadName : IO (Either Errno String)
getThreadName = do
  buf <- malloc 16
  r <- primIO (prim__get_name buf)
  res <- if r == 0 then pure (Right (maybe "" id (ptrToString buf))) else Left <$> errno
  free buf
  pure res

||| The signal this process gets when its parent thread ends (`Nothing`: none).
||| It is cleared in a child made by `fork`.
export
setParentDeathSignal : Maybe Signal -> IO (Either Errno ())
setParentDeathSignal sig =
  primIO (prim__set_pdeathsig (maybe 0 cast sig)) >>= checkUnit

||| The signal set by `setParentDeathSignal`.
export
getParentDeathSignal : IO (Either Errno (Maybe Signal))
getParentDeathSignal = map (map (\n => if n == 0 then Nothing else Just (cast n))) (outInt prim__get_pdeathsig)

||| Whether a core dump may be written, and the process can be attached to by `ptrace`.
export
setDumpable : Bool -> IO (Either Errno ())
setDumpable b = primIO (prim__set_dumpable (toInt b)) >>= checkUnit

||| `True` when the process is dumpable (1); a process that only root may dump (2,
||| after a setuid `exec`) is `False`.
export
getDumpable : IO (Either Errno Bool)
getDumpable = map (map (== 1)) (primIO prim__get_dumpable >>= checkNonNeg)

||| Make this process adopt the orphaned descendants of its children, instead
||| of `init`.
export
setChildSubreaper : Bool -> IO (Either Errno ())
setChildSubreaper b = primIO (prim__set_subreaper (toInt b)) >>= checkUnit

export
getChildSubreaper : IO (Either Errno Bool)
getChildSubreaper = map (map (/= 0)) (outInt prim__get_subreaper)

||| Forbid this process and its children to gain privileges through `exec` (a
||| setuid file, file capabilities). It cannot be undone.
export
setNoNewPrivs : IO (Either Errno ())
setNoNewPrivs = primIO prim__set_no_new_privs >>= checkUnit

export
getNoNewPrivs : IO (Either Errno Bool)
getNoNewPrivs = map (map (/= 0)) (primIO prim__get_no_new_privs >>= checkNonNeg)
