||| `posix_spawn`: start a program in a new process, with two of our descriptors as
||| its standard input and output. Unlike `fork` followed by `execve` it is safe
||| in a program with threads, and the child gets no other descriptor of ours.
|||
||| Linux (glibc 2.34 or later: `posix_spawn_file_actions_addclosefrom_np`, and
||| `..._addchdir_np` from 2.29). glibc declares those only under `_GNU_SOURCE`: build the program with
||| `IDRIS2_CFLAGS=-D_GNU_SOURCE`.
module System.Posix.Spawn

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import System.FFI
import System.Posix.Errno
import System.Posix.FileDesc
import System.Posix.Process

%default total

-- The child: it changes to the directory `$6`, `$3` and `$4` become its descriptors 0 and 1, every descriptor from 3
-- on is closed, and SIGPIPE has its default action again (`ignoreSigpipe` of the
-- parent is inherited by `exec` otherwise). The result is the process ID, or
-- minus the error number.
%foreign "CExpr:((int)({ posix_spawn_file_actions_t fa; posix_spawnattr_t at; sigset_t sd; pid_t p = 0; posix_spawn_file_actions_init(&fa); posix_spawn_file_actions_addchdir_np(&fa, $6); posix_spawn_file_actions_adddup2(&fa, $3, 0); posix_spawn_file_actions_adddup2(&fa, $4, 1); posix_spawn_file_actions_addclosefrom_np(&fa, 3); sigemptyset(&sd); sigaddset(&sd, SIGPIPE); posix_spawnattr_init(&at); posix_spawnattr_setsigdefault(&at, &sd); posix_spawnattr_setflags(&at, POSIX_SPAWN_SETSIGDEF); int r = posix_spawn(&p, $1, &fa, &at, (char *const *)($2), (char *const *)($5)); posix_spawnattr_destroy(&at); posix_spawn_file_actions_destroy(&fa); r == 0 ? (int)p : -r; })),libc,spawn.h;signal.h;sys/types.h"
prim__spawn : String -> AnyPtr -> Int32 -> Int32 -> AnyPtr -> String -> PrimIO Int32

%foreign "CExpr:(signal(SIGPIPE, SIG_IGN) == SIG_ERR ? -1 : 0),libc,signal.h"
prim__ignoreSigpipe : PrimIO Int32

||| Start the program at `path` (no `PATH` lookup, and a relative `path` is taken
||| from `cwd`, which is the directory the program starts in) with `argv` (the
||| program name first) and exactly the environment `envp` (`NAME=value`). Its
||| standard input is
||| `stdin` and its standard output `stdout`; the standard error is ours, and no
||| other descriptor is passed on. The descriptors stay open in the caller. `Left`
||| when the program cannot be started (`ENOENT`, `EACCES`, ...).
export
spawnStdio : (path, cwd : String) -> (argv, envp : List String) -> (stdin, stdout : FileDesc)
          -> IO (Either Errno ProcessID)
spawnStdio path cwd argv envp stdin stdout = do
  a <- newArgv argv
  e <- newArgv envp
  r <- primIO (prim__spawn path a stdin.rawfd stdout.rawfd e cwd)
  freeArgv (length argv) a
  freeArgv (length envp) e
  pure (if r > 0 then Right (MkProcessID r) else Left (MkErrno (negate r)))

||| Ignore SIGPIPE in this process, so that writing to a pipe whose reader has gone
||| is the error `EPIPE` and not the end of the program. (Sockets are written with
||| `MSG_NOSIGNAL` instead.) A program started with `spawnStdio` has the default
||| action again.
export
ignoreSigpipe : IO ()
ignoreSigpipe = ignore (primIO prim__ignoreSigpipe)
