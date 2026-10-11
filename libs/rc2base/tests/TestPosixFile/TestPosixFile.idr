module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- System.Posix.File and System.Posix.FileDesc: every "CExpr:" binding
-- that compiles under the default feature macros is called at least once. The open/AT_* flag values are compared (through
-- the .expected file) with what a plain C program prints for the same
-- macros on Linux; the rest is a round trip over a scratch directory
-- created under the current directory and removed again before exit.
-- O_DIRECT, O_LARGEFILE, O_NOATIME, O_PATH, O_TMPFILE, AT_EMPTY_PATH,
-- SEEK_DATA, SEEK_HOLE, dup3 need _GNU_SOURCE, which generated code does
-- not define: they are not called here (TODO.md, "CExpr feature requests").
-- The Posix modules have no O_RDONLY/O_WRONLY/O_RDWR or S_I* constants,
-- so the access modes (0/1/2) and permission bits are literals here.

import Data.Bits
import Data.Buffer
import System.Directory
import System.File
import System.FFI
import System.Posix.Errno
import System.Posix.File

dir : String
dir = "TestPosixFile.scratch"

path : String
path = dir ++ "/file.txt"

flag : String -> Bits32 -> IO ()
flag n v = putStrLn (n ++ "=" ++ show v)

check : String -> Bool -> IO ()
check n ok = putStrLn (n ++ ": " ++ (if ok then "ok" else "FAILED"))

main : IO ()
main = do
  flag "O_APPEND" O_APPEND
  flag "O_ASYNC" O_ASYNC
  flag "O_CLOEXEC" O_CLOEXEC
  flag "O_CREAT" O_CREAT
  flag "O_DIRECTORY" O_DIRECTORY
  flag "O_DSYNC" O_DSYNC
  flag "O_EXCL" O_EXCL
  flag "O_NOCTTY" O_NOCTTY
  flag "O_NOFOLLOW" O_NOFOLLOW
  flag "O_NONBLOCK" O_NONBLOCK
  flag "O_SYNC" O_SYNC
  flag "O_TRUNC" O_TRUNC
  flag "AT_SYMLINK_NOFOLLOW" AT_SYMLINK_NOFOLLOW
  -- scratch directory
  _ <- removeFile path
  _ <- removeDir dir
  Right () <- createDir dir
    | Left _ => putStrLn "createDir failed"
  -- creat / String.write / fsync / fdatasync / lseek / close
  Just fd <- creat path 420
    | Nothing => putStrLn "creat failed"
  n <- String.write fd "hello world\n"
  putStrLn ("write: " ++ show n)
  fsync fd >>= \r => putStrLn ("fsync: " ++ show r)
  fdatasync fd >>= \r => putStrLn ("fdatasync: " ++ show r)
  sync
  lseek fd (cast 0) SEEK_CUR >>= \r => putStrLn ("SEEK_CUR: " ++ show r)
  lseek fd (cast 3) SEEK_SET >>= \r => putStrLn ("SEEK_SET: " ++ show r)
  lseek fd (cast (-2)) SEEK_END >>= \r => putStrLn ("SEEK_END: " ++ show r)
  close fd >>= \r => putStrLn ("close: " ++ show r)
  -- open / AnyPtr.read / Buffer.read
  Just rfd <- openFile path 0 0
    | Nothing => putStrLn "open failed"
  Just buf <- newBuffer 12
    | Nothing => putStrLn "newBuffer failed"
  m <- Buffer.read rfd buf
  s <- getString buf 0 12
  putStrLn ("Buffer.read: " ++ show m ++ " " ++ show s)
  _ <- lseek rfd (cast 6) SEEK_SET
  p <- malloc 16
  k <- AnyPtr.read rfd p 5
  putStrLn ("AnyPtr.read: " ++ show k)
  free p
  -- dup / dup2 / dup3
  Just d1 <- dup rfd
    | Nothing => putStrLn "dup failed"
  check "dup" (d1.rawfd /= rfd.rawfd)
  Just d2 <- dup2 rfd (MkFileDesc 99)
    | Nothing => putStrLn "dup2 failed"
  putStrLn ("dup2: " ++ show d2.rawfd)
  for_ [d1, d2, rfd] $ \f => close f
  -- read/write open: Buffer.write, AnyPtr.write, pread/pwrite, locks, mode
  Just wfd <- openFile path (2 .|. O_APPEND) 0
    | Nothing => putStrLn "open rw failed"
  Just wbuf <- newBuffer 3
    | Nothing => putStrLn "newBuffer failed"
  setString wbuf 0 "abc"
  Buffer.write wfd wbuf >>= \r => putStrLn ("Buffer.write: " ++ show r)
  q <- malloc 2
  free q
  flockShared wfd >>= \r => putStrLn ("flockShared: " ++ show r)
  flockExclude wfd >>= \r => putStrLn ("flockExclude: " ++ show r)
  funlock wfd >>= \r => putStrLn ("funlock: " ++ show r)
  lockf wfd 0 >>= \r => putStrLn ("lockf: " ++ show r)
  lockfTest wfd 0 >>= \r => putStrLn ("lockfTest: " ++ show r)
  lockfUnlock wfd 0 >>= \r => putStrLn ("lockfUnlock: " ++ show r)
  lockfTestAndLock wfd 0 >>= \r => putStrLn ("lockfTestAndLock: " ++ show r)
  lockfUnlock wfd 0 >>= \r => putStrLn ("lockfUnlock: " ++ show r)
  fchmod wfd 384 >>= \r => putStrLn ("fchmod: " ++ show r)
  fchown wfd 4294967295 4294967295 >>= \r => putStrLn ("fchown: " ++ show r)
  fallocate wfd (cast 0) (cast 4096) >>= \r => putStrLn ("fallocate: " ++ show r)
  close wfd >>= \r => putStrLn ("close: " ++ show r)
  -- path based chmod/chown, *at variants relative to a directory descriptor
  chmod path 420 >>= \r => putStrLn ("chmod: " ++ show r)
  chown path 4294967295 4294967295 >>= \r => putStrLn ("chown: " ++ show r)
  lchown path 4294967295 4294967295 >>= \r => putStrLn ("lchown: " ++ show r)
  Just dfd <- openFile dir O_DIRECTORY 0
    | Nothing => putStrLn "open dir failed"
  let dd = MkDirDesc dfd.rawfd
  fchmodat dd "file.txt" 384 0 >>= \r => putStrLn ("fchmodat: " ++ show r)
  fchownat dd "file.txt" 4294967295 4294967295 0 >>= \r => putStrLn ("fchownat: " ++ show r)
  Just afd <- openat dd "file.txt" 0 0
    | Nothing => putStrLn "openat failed"
  close afd >>= \r => putStrLn ("openat+close: " ++ show r)
  close dfd >>= \r => putStrLn ("close dir: " ++ show r)
  -- a failing open: Nothing, errno == ENOENT
  Nothing <- openFile (dir ++ "/missing/file") 0 0
    | Just _ => putStrLn "open of a missing file succeeded"
  e <- errno
  putStrLn ("errno: " ++ show (e == ENOENT))
  -- clean up
  _ <- removeFile path
  _ <- removeDir dir
  putStrLn "done"
  ignore $ fflush stdout
  perror "perror-test"
