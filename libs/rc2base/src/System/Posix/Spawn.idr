||| `posix_spawn`: start a program in a new process, with two of our descriptors as
||| its standard input and output. Unlike `fork` followed by `execve` it is safe
||| in a program with threads, and the child gets no other descriptor of ours.
|||
||| Linux (glibc 2.34 or later: `posix_spawn_file_actions_addclosefrom_np`, and
||| `..._addchdir_np` from 2.29). glibc declares those only under `_GNU_SOURCE`:
||| build the program with `IDRIS2_CFLAGS=-D_GNU_SOURCE`.
module System.Posix.Spawn

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import System.FFI
import System.Posix.Errno
import System.Posix.FileDesc
import System.Posix.Process

%default total

-------------------------------------------------------------------------------
-- The C types are opaque and as big as the platform makes them: they are
-- allocated with their `sizeof`.

%inline %foreign "CExpr:(sizeof(posix_spawn_file_actions_t)),libc,spawn.h"
prim__sizeofFileActions : Int
%inline %foreign "CExpr:(sizeof(posix_spawnattr_t)),libc,spawn.h"
prim__sizeofAttr : Int
%inline %foreign "CExpr:(sizeof(sigset_t)),libc,signal.h"
prim__sizeofSigset : Int
%inline %foreign "CExpr:(sizeof(pid_t)),libc,sys/types.h"
prim__sizeofPid : Int

-------------------------------------------------------------------------------
-- File actions: what the child does between `fork` and `exec`. Every call
-- answers 0 or an error number (not `errno`).

%inline %foreign "CExpr:(posix_spawn_file_actions_init((posix_spawn_file_actions_t *)($1))),libc,spawn.h"
prim__fileActionsInit : AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(posix_spawn_file_actions_destroy((posix_spawn_file_actions_t *)($1))),libc,spawn.h"
prim__fileActionsDestroy : AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(posix_spawn_file_actions_adddup2((posix_spawn_file_actions_t *)($1), $2, $3)),libc,spawn.h"
prim__addDup2 : AnyPtr -> (from, to : Int32) -> PrimIO Int32
%inline %foreign "CExpr:(posix_spawn_file_actions_addchdir_np((posix_spawn_file_actions_t *)($1), $2)),libc,spawn.h"
prim__addChdir : AnyPtr -> String -> PrimIO Int32
%inline %foreign "CExpr:(posix_spawn_file_actions_addclosefrom_np((posix_spawn_file_actions_t *)($1), $2)),libc,spawn.h"
prim__addCloseFrom : AnyPtr -> (lowfd : Int32) -> PrimIO Int32

-------------------------------------------------------------------------------
-- Attributes: the signal mask, and the signals that get their default action again.

%inline %foreign "CExpr:(posix_spawnattr_init((posix_spawnattr_t *)($1))),libc,spawn.h"
prim__attrInit : AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(posix_spawnattr_destroy((posix_spawnattr_t *)($1))),libc,spawn.h"
prim__attrDestroy : AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(posix_spawnattr_setsigdefault((posix_spawnattr_t *)($1), (const sigset_t *)($2))),libc,spawn.h;signal.h"
prim__attrSetSigDefault : AnyPtr -> (sigset : AnyPtr) -> PrimIO Int32
%inline %foreign "CExpr:(posix_spawnattr_setflags((posix_spawnattr_t *)($1), (short)($2))),libc,spawn.h"
prim__attrSetFlags : AnyPtr -> (flags : Int32) -> PrimIO Int32
%inline %foreign "CExpr:(posix_spawnattr_setsigmask((posix_spawnattr_t *)($1), (const sigset_t *)($2))),libc,spawn.h;signal.h"
prim__attrSetSigMask : AnyPtr -> (sigset : AnyPtr) -> PrimIO Int32
%inline %foreign "CExpr:(posix_spawnattr_setpgroup((posix_spawnattr_t *)($1), $2)),libc,spawn.h"
prim__attrSetPgroup : AnyPtr -> (pgid : Int32) -> PrimIO Int32
%inline %foreign "CExpr:(POSIX_SPAWN_SETSIGDEF),libc,spawn.h"
prim__SETSIGDEF : Int32
%inline %foreign "CExpr:(POSIX_SPAWN_SETSIGMASK),libc,spawn.h"
prim__SETSIGMASK : Int32
%inline %foreign "CExpr:(POSIX_SPAWN_SETPGROUP),libc,spawn.h"
prim__SETPGROUP : Int32

%inline %foreign "CExpr:(sigemptyset((sigset_t *)($1))),libc,signal.h"
prim__sigemptyset : AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(sigfillset((sigset_t *)($1))),libc,signal.h"
prim__sigfillset : AnyPtr -> PrimIO Int32

-------------------------------------------------------------------------------
-- The call itself: the process ID is written to `$6`.

%inline %foreign "CExpr:(posix_spawn((pid_t *)($6), $1, (const posix_spawn_file_actions_t *)($2), (const posix_spawnattr_t *)($3), (char *const *)($4), (char *const *)($5))),libc,spawn.h"
prim__spawn : (path : String) -> (fileActions, attr, argv, envp, pid : AnyPtr) -> PrimIO Int32
%inline %foreign "CExpr:(*(pid_t *)($1)),libc,sys/types.h"
prim__readPid : AnyPtr -> PrimIO Int32

%foreign "CExpr:(signal(SIGPIPE, SIG_IGN) == SIG_ERR ? -1 : 0),libc,signal.h"
prim__ignoreSigpipe : PrimIO Int32

-- The attributes that are set: the signals' default actions and mask, the group.
attrFlags : Int32
attrFlags = prim__SETSIGDEF + prim__SETSIGMASK + prim__SETPGROUP   -- distinct bits

-- Run the calls one after the other, up to the first that fails; its error number.
runSteps : List (PrimIO Int32) -> IO Int32
runSteps [] = pure 0
runSteps (step :: rest) = do
  r <- primIO step
  if r /= 0 then pure r else runSteps rest

||| Start the program at `path` (no `PATH` lookup, and a relative `path` is taken
||| from `cwd`, which is the directory the program starts in) with `argv` (the
||| program name first) and exactly the environment `envp` (`NAME=value`). Its
||| standard input is `stdin` and its standard output `stdout`; the standard error
||| is ours, and no other descriptor is passed on. The program is a process group
||| of its own (its process ID is the group's: `kill (-pid)` ends it and what it
||| started), has no blocked signal (the caller may block some, for `signalfd`), and every
||| signal has its default action (not the `SIG_IGN` the caller set, which `exec` keeps). The
||| descriptors stay open in the caller. `Left` when the program cannot be started (`ENOENT`, `EACCES`, ...).
export
spawnStdio : (path, cwd : String) -> (argv, envp : List String) -> (stdin, stdout : FileDesc)
          -> IO (Either Errno ProcessID)
spawnStdio path cwd argv envp stdin stdout = do
  actions <- malloc prim__sizeofFileActions
  attr <- malloc prim__sizeofAttr
  sigs <- malloc prim__sizeofSigset
  noSigs <- malloc prim__sizeofSigset
  pid <- malloc prim__sizeofPid
  a <- newArgv argv
  e <- newArgv envp
  -- the two are destroyed only when they were made
  actionsMade <- primIO (prim__fileActionsInit actions)
  attrMade <- if actionsMade == 0 then primIO (prim__attrInit attr) else pure actionsMade
  r <- if attrMade /= 0 then pure attrMade else
         runSteps [ prim__addChdir actions cwd
                  , prim__addDup2 actions stdin.rawfd 0
                  , prim__addDup2 actions stdout.rawfd 1
                  , prim__addCloseFrom actions 3
                  , prim__sigfillset sigs
                  , prim__sigemptyset noSigs
                  , prim__attrSetSigDefault attr sigs
                  , prim__attrSetSigMask attr noSigs
                  , prim__attrSetPgroup attr 0
                  , prim__attrSetFlags attr attrFlags
                  , prim__spawn path actions attr a e pid ]
  when (attrMade == 0) $ ignore (primIO (prim__attrDestroy attr))
  when (actionsMade == 0) $ ignore (primIO (prim__fileActionsDestroy actions))
  started <- primIO (prim__readPid pid)
  freeArgv (length argv) a
  freeArgv (length envp) e
  traverse_ free [actions, attr, sigs, noSigs, pid]
  pure (if r == 0 then Right (MkProcessID started) else Left (MkErrno r))

||| Ignore SIGPIPE in this process, so that writing to a pipe whose reader has gone
||| is the error `EPIPE` and not the end of the program. (Sockets are written with
||| `MSG_NOSIGNAL` instead.) A program started with `spawnStdio` has the default
||| action again.
export
ignoreSigpipe : IO ()
ignoreSigpipe = ignore (primIO prim__ignoreSigpipe)
