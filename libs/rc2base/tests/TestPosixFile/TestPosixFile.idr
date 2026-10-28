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
import Data.List
import Data.String
import Data.Buffer
import System.Directory
import System.File
import System.FFI
import System.Posix.Errno
import System.Posix.File
import System.Posix.Glob
import System.Posix.Path
import System.Posix.Stat
import System.Posix.Time
dir : String
dir = "TestPosixFile.scratch"

path : String
path = dir ++ "/file.txt"

flag : String -> Bits32 -> IO ()
flag n v = putStrLn (n ++ "=" ++ show v)

check : String -> Bool -> IO ()
check n ok = putStrLn (n ++ ": " ++ (if ok then "ok" else "FAILED"))

-----------------------------------------------------------------------------
-- Setup and teardown (System.Directory/System.File, not under test)
-----------------------------------------------------------------------------

||| Start from an empty scratch directory.
setup : IO ()
setup = do
  _ <- removeFile path
  _ <- removeDir dir
  Right () <- createDir dir
    | Left _ => putStrLn "createDir failed"
  pure ()

||| Remove the scratch directory.
teardown : IO ()
teardown = do
  _ <- removeFile path
  _ <- removeDir dir
  pure ()

-----------------------------------------------------------------------------
-- Tests (System.Posix.File under test)
-----------------------------------------------------------------------------

||| The O_* / AT_* constants.
testFlags : IO ()
testFlags = do
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
  flag "O_RDONLY" O_RDONLY
  flag "O_WRONLY" O_WRONLY
  flag "O_RDWR" O_RDWR
  flag "AT_SYMLINK_NOFOLLOW" AT_SYMLINK_NOFOLLOW

||| creat / String.write / fsync / fdatasync / sync / lseek / close.
testCreateAndSeek : IO ()
testCreateAndSeek = do
  Right fd <- creat path 420
    | Left e => putStrLn ("creat failed: " ++ show e)
  n <- String.write fd "hello world\n"
  putStrLn ("write: " ++ show n)
  fsync fd >>= \r => putStrLn ("fsync: " ++ show r)
  fdatasync fd >>= \r => putStrLn ("fdatasync: " ++ show r)
  sync
  lseek fd (cast 0) SEEK_CUR >>= \r => putStrLn ("SEEK_CUR: " ++ show r)
  lseek fd (cast 3) SEEK_SET >>= \r => putStrLn ("SEEK_SET: " ++ show r)
  lseek fd (cast (-2)) SEEK_END >>= \r => putStrLn ("SEEK_END: " ++ show r)
  close fd >>= \r => putStrLn ("close: " ++ show r)

||| openFile / Buffer.read / AnyPtr.read / dup / dup2.
testReadAndDup : IO ()
testReadAndDup = do
  Right rfd <- openFile path 0 0
    | Left e => putStrLn ("open failed: " ++ show e)
  Just buf <- newBuffer 12
    | Nothing => putStrLn "newBuffer failed"
  m <- Buffer.read rfd buf
  s <- getString buf 0 12
  putStrLn ("Buffer.read: " ++ show m ++ " " ++ show s)
  _ <- lseek rfd (cast 6) SEEK_SET
  -- a failure is the errno: posix_fallocate on a descriptor not open for writing
  fallocate rfd (cast 0) (cast 4096) >>= \r => putStrLn ("fallocate read-only is EBADF: " ++ show (r == Left EBADF))
  p <- malloc 16
  k <- AnyPtr.read rfd p 5
  putStrLn ("AnyPtr.read: " ++ show k)
  free p
  -- dup / dup2 / dup3
  Right d1 <- dup rfd
    | Left e => putStrLn ("dup failed: " ++ show e)
  check "dup" (d1.rawfd /= rfd.rawfd)
  Right d2 <- dup2 rfd (MkFileDesc 99)
    | Left e => putStrLn ("dup2 failed: " ++ show e)
  putStrLn ("dup2: " ++ show d2.rawfd)
  for_ [d1, d2, rfd] $ \f => close f

||| Read/write open: Buffer.write, flock, lockf, fchmod, fchown, fallocate.
testWriteAndLocks : IO ()
testWriteAndLocks = do
  Right wfd <- openFile path (2 .|. O_APPEND) 0
    | Left e => putStrLn ("open rw failed: " ++ show e)
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

||| Path based chmod/chown/lchown and the *at variants relative to a directory descriptor.
testPathBased : IO ()
testPathBased = do
  chmod (dir ++ "/missing") 420 >>= \r => putStrLn ("chmod missing is ENOENT: " ++ show (r == Left ENOENT))
  chmod path 420 >>= \r => putStrLn ("chmod: " ++ show r)
  chown path 4294967295 4294967295 >>= \r => putStrLn ("chown: " ++ show r)
  lchown path 4294967295 4294967295 >>= \r => putStrLn ("lchown: " ++ show r)
  Right dfd <- openFile dir O_DIRECTORY 0
    | Left e => putStrLn ("open dir failed: " ++ show e)
  let dd = asDirDesc dfd
  fchmodat dd "file.txt" 384 0 >>= \r => putStrLn ("fchmodat: " ++ show r)
  fchownat dd "file.txt" 4294967295 4294967295 0 >>= \r => putStrLn ("fchownat: " ++ show r)
  Right afd <- openat dd "file.txt" 0 0
    | Left e => putStrLn ("openat failed: " ++ show e)
  close afd >>= \r => putStrLn ("openat+close: " ++ show r)
  close dfd >>= \r => putStrLn ("close dir: " ++ show r)

||| A failing open: Left errno, errno == ENOENT.
testMissingFile : IO ()
testMissingFile = do
  Left e <- openFile (dir ++ "/missing/file") 0 0
    | Right _ => putStrLn "open of a missing file succeeded"
  putStrLn ("errno: " ++ show (e == ENOENT))

-----------------------------------------------------------------------------
-- main
-----------------------------------------------------------------------------

-----------------------------------------------------------------------------
-- System.Posix.Stat, System.Posix.Path and utimensat/ftruncate
-----------------------------------------------------------------------------

errMsg : Errno -> String
errMsg (MkErrno e) = "errno " ++ show e

errOf : Either Errno a -> String
errOf (Left e) = errMsg e
errOf (Right _) = "ok"

unit : String -> Either Errno () -> IO ()
unit n r = putStrLn (n ++ ": " ++ errOf r)

testStat : IO ()
testStat = do
  putStrLn "-- stat"
  -- path holds "hello" (5 bytes) at this point; make sure of it
  Right fd <- creat path 0o640
    | Left _ => putStrLn "creat failed"
  _ <- write fd "hello"
  _ <- close fd
  Right st <- stat path
    | Left e => putStrLn ("stat failed: " ++ errMsg e)
  putStrLn ("size=" ++ show st.stSize ++ " nlink=" ++ show st.stNlink)
  putStrLn ("regular=" ++ show (isRegular st) ++ " dir=" ++ show (isDirectory st)
            ++ " link=" ++ show (isSymlink st) ++ " fifo=" ++ show (isFifo st))
  putStrLn ("mode bits type=" ++ show (fileType st == S_IFREG))
  Right fd2 <- openFile path 0 0
    | Left _ => putStrLn "open failed"
  Right fst' <- fstat fd2
    | Left _ => putStrLn "fstat failed"
  putStrLn ("fstat same inode: " ++ show (fst'.stIno == st.stIno && fst'.stDev == st.stDev))
  _ <- close fd2
  Right dst <- stat dir
    | Left _ => putStrLn "stat dir failed"
  putStrLn ("dir is directory: " ++ show (isDirectory dst))
  Left e <- stat (dir ++ "/missing")
    | Right _ => putStrLn "stat missing: unexpectedly ok"
  putStrLn ("stat missing: " ++ errMsg e)
  putStrLn ("mtime is positive: " ++ show (st.stMtime.tvSec > 0))

testPath : IO ()
testPath = do
  putStrLn "-- path"
  let sub = dir ++ "/sub"
  let lnk = dir ++ "/lnk"
  let hard = dir ++ "/hard"
  let fifo = dir ++ "/fifo"
  unit "mkdir" !(mkdir sub 0o755)
  unit "mkdir again" !(mkdir sub 0o755)
  Right sst <- stat sub
    | Left _ => putStrLn "stat sub failed"
  putStrLn ("sub is directory: " ++ show (isDirectory sst))
  unit "rmdir" !(rmdir sub)
  unit "symlink" !(symlink "file.txt" lnk)
  readlink lnk >>= \r => putStrLn ("readlink: " ++ show r)
  Right lst <- lstat lnk
    | Left _ => putStrLn "lstat failed"
  putStrLn ("lstat is symlink: " ++ show (isSymlink lst))
  Right tst <- stat lnk
    | Left _ => putStrLn "stat through link failed"
  putStrLn ("stat follows the link: " ++ show (isRegular tst))
  unit "link" !(link path hard)
  Right hst <- stat path
    | Left _ => putStrLn "stat failed"
  putStrLn ("nlink after link: " ++ show hst.stNlink)
  unit "unlink hard" !(unlink hard)
  unit "unlink lnk" !(unlink lnk)
  unit "mkfifo" !(mkfifo fifo 0o600)
  Right fst' <- stat fifo
    | Left _ => putStrLn "stat fifo failed"
  putStrLn ("fifo: " ++ show (isFifo fst'))
  unit "unlink fifo" !(unlink fifo)
  Right rp <- realpath (dir ++ "/./file.txt")
    | Left _ => putStrLn "realpath failed"
  putStrLn ("realpath ends with: " ++ show (isSuffixOf ("/" ++ dir ++ "/file.txt") rp))
  Left e <- realpath (dir ++ "/missing")
    | Right _ => putStrLn "realpath missing: unexpectedly ok"
  putStrLn ("realpath missing: " ++ errMsg e)
  Right (tfd, tname) <- mkstemp (dir ++ "/tmpXXXXXX")
    | Left _ => putStrLn "mkstemp failed"
  putStrLn ("mkstemp name: " ++ show (isPrefixOf (dir ++ "/tmp") tname && length tname == length (dir ++ "/tmpXXXXXX")))
  _ <- close tfd
  unit "unlink temp" !(unlink tname)
  Right dname <- mkdtemp (dir ++ "/dXXXXXX")
    | Left _ => putStrLn "mkdtemp failed"
  Right dtst <- stat dname
    | Left _ => putStrLn "stat temp dir failed"
  putStrLn ("mkdtemp is directory: " ++ show (isDirectory dtst))
  unit "rmdir temp" !(rmdir dname)

testAttrs : IO ()
testAttrs = do
  putStrLn "-- access/truncate/umask/utimensat"
  unit "access F_OK" !(access path F_OK)
  unit "access R_OK" !(access path R_OK)
  Left e <- access (dir ++ "/missing") F_OK
    | Right _ => putStrLn "access missing: unexpectedly ok"
  putStrLn ("access missing: " ++ errMsg e)
  unit "truncate" !(truncate path 2)
  Right t1 <- stat path
    | Left _ => putStrLn "stat failed"
  putStrLn ("size after truncate: " ++ show t1.stSize)
  Right fd <- openFile path 1 0
    | Left _ => putStrLn "open failed"
  unit "ftruncate" !(ftruncate fd 9)
  _ <- close fd
  Right t2 <- stat path
    | Left _ => putStrLn "stat failed"
  putStrLn ("size after ftruncate: " ++ show t2.stSize)
  old <- umask 0o077
  back <- umask old
  putStrLn ("umask restored: " ++ show (back == 0o077))
  unit "utimensat" !(utimensat Nothing path (SetTo (MkTimeSpec 1000000000 500)) (SetTo (MkTimeSpec 1500000000 0)) 0)
  Right t3 <- stat path
    | Left _ => putStrLn "stat failed"
  putStrLn ("atime=" ++ show t3.stAtime ++ " mtime=" ++ show t3.stMtime)
  unit "utimensat omit" !(utimensat Nothing path Omit SetNow 0)
  Right t4 <- stat path
    | Left _ => putStrLn "stat failed"
  putStrLn ("atime kept: " ++ show (t4.stAtime == t3.stAtime) ++ ", mtime now: " ++ show (t4.stMtime.tvSec > 1500000000))

testGlob : IO ()
testGlob = do
  putStrLn "-- fnmatch, glob"
  let m = \pat, s, fl => fnmatch pat s fl >>= \b => putStrLn ("fnmatch " ++ pat ++ " " ++ s ++ " flags " ++ show fl ++ ": " ++ show b)
  m "*.txt" "file.txt" 0
  m "*.txt" "file.bin" 0
  m "f?le.t[a-z]t" "file.txt" 0
  m "*" ".hidden" 0
  m "*" ".hidden" FNM_PERIOD
  m "a*" "a/b" 0
  m "a*" "a/b" FNM_PATHNAME
  m "\\*" "*" 0
  m "\\*" "\\*" FNM_NOESCAPE
  glob (dir ++ "/*.txt") 0 >>= \r => putStrLn ("glob *.txt: " ++ show r)
  glob (dir ++ "/nothing*") 0 >>= \r => putStrLn ("glob no match: " ++ show r)
  glob (dir ++ "/nothing*") GLOB_NOCHECK >>= \r => putStrLn ("glob no match, NOCHECK: " ++ show r)
  glob dir GLOB_MARK >>= \r => putStrLn ("glob directory, MARK: " ++ show r)

main : IO ()
main = do
  testFlags
  setup
  testCreateAndSeek
  testReadAndDup
  testWriteAndLocks
  testPathBased
  testMissingFile
  testStat
  testPath
  testAttrs
  testGlob
  teardown
  putStrLn "done"
  ignore $ fflush stdout
  perror "perror-test"
