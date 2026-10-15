module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- System.Posix.Directory: opendir/fdopendir/closedir/rewinddir/telldir/
-- seekdir/dirfd over a scratch directory with two files, chdir/fchdir/
-- getcwd/chroot, and the DT_*/PATH_MAX constants (compared with a plain
-- C program through the .expected file), and a readdir loop over a scratch
-- tree (regular files, a subdirectory, a symlink) sorted by name.

import Data.List
import Data.String
import System.Directory
import System.File
import System.Posix.Errno
import System.Posix.Directory
import System.Posix.File

%foreign "CExpr:(symlink($1, $2)),libc,unistd.h"
prim__symlink : String -> String -> PrimIO Int32

dir : String
dir = "TestPosixDirectory.scratch"

-----------------------------------------------------------------------------
-- Setup and teardown (System.Directory/System.File and creat, not under test)
-----------------------------------------------------------------------------

||| Start from an empty scratch directory holding files a, b, a directory sub and a symlink link.
setup : IO ()
setup = do
  _ <- removeFile (dir ++ "/a")
  _ <- removeFile (dir ++ "/b")
  _ <- removeFile (dir ++ "/link")
  _ <- removeDir (dir ++ "/sub")
  _ <- removeDir dir
  Right () <- createDir dir
    | Left _ => putStrLn "createDir failed"
  Right fd <- creat (dir ++ "/a") 420
    | Left e => putStrLn ("creat failed: " ++ show e)
  _ <- close fd
  Right () <- createDir (dir ++ "/sub")
    | Left _ => putStrLn "createDir sub failed"
  Right f2 <- creat (dir ++ "/b") 420
    | Left e => putStrLn ("creat b failed: " ++ show e)
  _ <- close f2
  _ <- primIO (prim__symlink "a" (dir ++ "/link"))
  pure ()

||| Remove everything setup made.
teardown : IO ()
teardown = do
  _ <- removeFile (dir ++ "/a")
  _ <- removeFile (dir ++ "/b")
  _ <- removeFile (dir ++ "/link")
  _ <- removeDir (dir ++ "/sub")
  _ <- removeDir dir
  pure ()

-----------------------------------------------------------------------------
-- Tests (System.Posix.Directory under test)
-----------------------------------------------------------------------------

||| The DT_* constants and PATH_MAX.
testConstants : IO ()
testConstants = do
  putStrLn ("DT_BLK=" ++ show DT_BLK)
  putStrLn ("DT_CHR=" ++ show DT_CHR)
  putStrLn ("DT_DIR=" ++ show DT_DIR)
  putStrLn ("DT_FIFO=" ++ show DT_FIFO)
  putStrLn ("DT_LINK=" ++ show DT_LINK)
  putStrLn ("DT_REG=" ++ show DT_REG)
  putStrLn ("DT_SOCK=" ++ show DT_SOCK)
  putStrLn ("DT_UNKNOWN=" ++ show DT_UNKNOWN)
  putStrLn ("PATH_MAX=" ++ show PATH_MAX)

||| opendir / readDirEntries / closedir.
testListing : IO ()
testListing = do
  rd <- opendir dir
  es <- readDirEntries rd
  _ <- closedir rd
  for_ (sortBy (\x, y => compare x.name y.name) es) $ \e =>
    putStrLn ("entry " ++ e.name ++ " " ++ show e.type ++ " " ++ show (e.ino > 0))

||| dirfd / telldir / seekdir / rewinddir / closedir / fdopendir.
testDirfd : IO ()
testDirfd = do
  d <- opendir dir
  Right dd <- dirfd d
    | Left _ => putStrLn "dirfd failed"
  putStrLn ("dirfd ok: " ++ show (dd.rawdirfd >= 0))
  pos <- telldir d
  seekdir d pos
  rewinddir d
  closedir d >>= \r => putStrLn ("closedir: " ++ show r)
  Right dfd <- openFile dir 0 0
    | Left e => putStrLn ("open dir failed: " ++ show e)
  d2 <- fdopendir dfd
  closedir d2 >>= \r => putStrLn ("closedir fdopendir: " ++ show r)

||| chdir into the scratch directory and back with fchdir; chroot and chdir on a missing path.
testChdir : IO ()
testChdir = do
  Just cwd0 <- getcwd
    | Nothing => putStrLn "getcwd failed"
  chdir dir >>= \r => putStrLn ("chdir: " ++ show r)
  Just cwd1 <- getcwd
    | Nothing => putStrLn "getcwd failed"
  putStrLn ("getcwd in scratch: " ++ show (isSuffixOf dir cwd1))
  Right back <- openFile cwd0 0 0
    | Left e => putStrLn ("open cwd failed: " ++ show e)
  fchdir (asDirDesc back) >>= \r => putStrLn ("fchdir: " ++ show r)
  Just cwd2 <- getcwd
    | Nothing => putStrLn "getcwd failed"
  putStrLn ("back to start: " ++ show (cwd2 == cwd0))
  _ <- close back
  chroot (dir ++ "/missing") >>= \r => putStrLn ("chroot missing: " ++ show r)
  chdir (dir ++ "/missing") >>= \r => putStrLn ("chdir missing: " ++ show r)

-----------------------------------------------------------------------------
-- main
-----------------------------------------------------------------------------

main : IO ()
main = do
  testConstants
  setup
  testListing
  testDirfd
  testChdir
  teardown
  putStrLn "done"
