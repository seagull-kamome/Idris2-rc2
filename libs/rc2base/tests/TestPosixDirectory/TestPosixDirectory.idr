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
import System.Posix.Directory
import System.Posix.File

%foreign "CExpr:(symlink($1, $2)),libc,unistd.h"
prim__symlink : String -> String -> PrimIO Int32

dir : String
dir = "TestPosixDirectory.scratch"

main : IO ()
main = do
  putStrLn ("DT_BLK=" ++ show DT_BLK)
  putStrLn ("DT_CHR=" ++ show DT_CHR)
  putStrLn ("DT_DIR=" ++ show DT_DIR)
  putStrLn ("DT_FIFO=" ++ show DT_FIFO)
  putStrLn ("DT_LINK=" ++ show DT_LINK)
  putStrLn ("DT_REG=" ++ show DT_REG)
  putStrLn ("DT_SOCK=" ++ show DT_SOCK)
  putStrLn ("DT_UNKNOWN=" ++ show DT_UNKNOWN)
  putStrLn ("PATH_MAX=" ++ show PATH_MAX)
  _ <- removeFile (dir ++ "/a")
  _ <- removeFile (dir ++ "/b")
  _ <- removeFile (dir ++ "/link")
  _ <- removeDir (dir ++ "/sub")
  _ <- removeDir dir
  Right () <- createDir dir
    | Left _ => putStrLn "createDir failed"
  Just fd <- creat (dir ++ "/a") 420
    | Nothing => putStrLn "creat failed"
  _ <- close fd
  Right () <- createDir (dir ++ "/sub")
    | Left _ => putStrLn "createDir sub failed"
  Just f2 <- creat (dir ++ "/b") 420
    | Nothing => putStrLn "creat b failed"
  _ <- close f2
  _ <- primIO (prim__symlink "a" (dir ++ "/link"))
  rd <- opendir dir
  es <- readDirEntries rd
  _ <- closedir rd
  for_ (sortBy (\x, y => compare x.name y.name) es) $ \e =>
    putStrLn ("entry " ++ e.name ++ " " ++ show e.type ++ " " ++ show (e.ino > 0))
  d <- opendir dir
  Just dd <- dirfd d
    | Nothing => putStrLn "dirfd failed"
  putStrLn ("dirfd ok: " ++ show (dd.rawdirfd >= 0))
  pos <- telldir d
  seekdir d pos
  rewinddir d
  closedir d >>= \r => putStrLn ("closedir: " ++ show r)
  Just dfd <- openFile dir 0 0
    | Nothing => putStrLn "open dir failed"
  d2 <- fdopendir dfd
  closedir d2 >>= \r => putStrLn ("closedir fdopendir: " ++ show r)
  -- chdir into the scratch directory and back with fchdir
  Just cwd0 <- getcwd
    | Nothing => putStrLn "getcwd failed"
  chdir dir >>= \r => putStrLn ("chdir: " ++ show r)
  Just cwd1 <- getcwd
    | Nothing => putStrLn "getcwd failed"
  putStrLn ("getcwd in scratch: " ++ show (isSuffixOf dir cwd1))
  Just back <- openFile cwd0 0 0
    | Nothing => putStrLn "open cwd failed"
  fchdir (MkDirDesc back.rawfd) >>= \r => putStrLn ("fchdir: " ++ show r)
  Just cwd2 <- getcwd
    | Nothing => putStrLn "getcwd failed"
  putStrLn ("back to start: " ++ show (cwd2 == cwd0))
  _ <- close back
  chroot (dir ++ "/missing") >>= \r => putStrLn ("chroot missing: " ++ show r)
  chdir (dir ++ "/missing") >>= \r => putStrLn ("chdir missing: " ++ show r)
  _ <- removeFile (dir ++ "/a")
  _ <- removeFile (dir ++ "/b")
  _ <- removeFile (dir ++ "/link")
  _ <- removeDir (dir ++ "/sub")
  _ <- removeDir dir
  putStrLn "done"
