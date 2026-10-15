||| File status: `stat`/`lstat`/`fstat`/`fstatat`, the `S_*` mode bits and
||| file-type tests, `access`, `truncate`/`ftruncate`, `umask` and
||| `utimensat`.
|||
||| `struct stat` is copied into the record `Stat` at once, so no C struct is
||| visible to the caller.
module System.Posix.Stat

import Data.Bits
import System.FFI
import System.Posix.Errno
import System.Posix.File
import System.Posix.FileDesc
import System.Posix.Time

%default total

-------------------------------------------------------------------------------
-- Mode bits

%inline %foreign "CExpr:(S_IFMT),libc,sys/stat.h"
prim__S_IFMT : Bits32
%inline %foreign "CExpr:(S_IFREG),libc,sys/stat.h"
prim__S_IFREG : Bits32
%inline %foreign "CExpr:(S_IFDIR),libc,sys/stat.h"
prim__S_IFDIR : Bits32
%inline %foreign "CExpr:(S_IFLNK),libc,sys/stat.h"
prim__S_IFLNK : Bits32
%inline %foreign "CExpr:(S_IFCHR),libc,sys/stat.h"
prim__S_IFCHR : Bits32
%inline %foreign "CExpr:(S_IFBLK),libc,sys/stat.h"
prim__S_IFBLK : Bits32
%inline %foreign "CExpr:(S_IFIFO),libc,sys/stat.h"
prim__S_IFIFO : Bits32
%inline %foreign "CExpr:(S_IFSOCK),libc,sys/stat.h"
prim__S_IFSOCK : Bits32

||| The mask of the file-type bits of `st_mode`.
export S_IFMT : Bits32
S_IFMT = prim__S_IFMT
||| File type: regular file.
export S_IFREG : Bits32
S_IFREG = prim__S_IFREG
||| File type: directory.
export S_IFDIR : Bits32
S_IFDIR = prim__S_IFDIR
||| File type: symbolic link.
export S_IFLNK : Bits32
S_IFLNK = prim__S_IFLNK
||| File type: character device.
export S_IFCHR : Bits32
S_IFCHR = prim__S_IFCHR
||| File type: block device.
export S_IFBLK : Bits32
S_IFBLK = prim__S_IFBLK
||| File type: FIFO.
export S_IFIFO : Bits32
S_IFIFO = prim__S_IFIFO
||| File type: socket.
export S_IFSOCK : Bits32
S_IFSOCK = prim__S_IFSOCK

%inline %foreign "CExpr:(S_ISUID),libc,sys/stat.h"
export S_ISUID : Bits32
%inline %foreign "CExpr:(S_ISGID),libc,sys/stat.h"
export S_ISGID : Bits32
%inline %foreign "CExpr:(S_ISVTX),libc,sys/stat.h"
export S_ISVTX : Bits32
%inline %foreign "CExpr:(S_IRWXU),libc,sys/stat.h"
export S_IRWXU : Bits32
%inline %foreign "CExpr:(S_IRUSR),libc,sys/stat.h"
export S_IRUSR : Bits32
%inline %foreign "CExpr:(S_IWUSR),libc,sys/stat.h"
export S_IWUSR : Bits32
%inline %foreign "CExpr:(S_IXUSR),libc,sys/stat.h"
export S_IXUSR : Bits32
%inline %foreign "CExpr:(S_IRWXG),libc,sys/stat.h"
export S_IRWXG : Bits32
%inline %foreign "CExpr:(S_IRGRP),libc,sys/stat.h"
export S_IRGRP : Bits32
%inline %foreign "CExpr:(S_IWGRP),libc,sys/stat.h"
export S_IWGRP : Bits32
%inline %foreign "CExpr:(S_IXGRP),libc,sys/stat.h"
export S_IXGRP : Bits32
%inline %foreign "CExpr:(S_IRWXO),libc,sys/stat.h"
export S_IRWXO : Bits32
%inline %foreign "CExpr:(S_IROTH),libc,sys/stat.h"
export S_IROTH : Bits32
%inline %foreign "CExpr:(S_IWOTH),libc,sys/stat.h"
export S_IWOTH : Bits32
%inline %foreign "CExpr:(S_IXOTH),libc,sys/stat.h"
export S_IXOTH : Bits32

-------------------------------------------------------------------------------
-- Stat

||| The fields of `struct stat` that POSIX requires. Times are `st_atim`,
||| `st_mtim`, `st_ctim` (POSIX.1-2008).
public export
record Stat where
  constructor MkStat
  stDev : Bits64
  stIno : Bits64
  stMode : Bits32
  stNlink : Bits64
  stUid : Bits32
  stGid : Bits32
  stRdev : Bits64
  stSize : Int64
  stBlksize : Int64
  stBlocks : Int64
  stAtime : TimeSpec
  stMtime : TimeSpec
  stCtime : TimeSpec

export
Show Stat where
  show s = "Stat dev=" ++ show s.stDev ++ " ino=" ++ show s.stIno ++ " mode=" ++ show s.stMode
        ++ " nlink=" ++ show s.stNlink ++ " uid=" ++ show s.stUid ++ " gid=" ++ show s.stGid
        ++ " size=" ++ show s.stSize ++ " mtime=" ++ show s.stMtime

||| The file-type bits of the mode.
export
fileType : Stat -> Bits32
fileType st = st.stMode .&. S_IFMT

||| The permission bits of the mode (including set-user-ID, set-group-ID and sticky).
export
permissions : Stat -> Bits32
permissions st = st.stMode .&. (S_ISUID .|. S_ISGID .|. S_ISVTX .|. S_IRWXU .|. S_IRWXG .|. S_IRWXO)

||| Is it a regular file?
export isRegular : Stat -> Bool
isRegular st = fileType st == S_IFREG
||| Is it a directory?
export isDirectory : Stat -> Bool
isDirectory st = fileType st == S_IFDIR
||| Is it a symbolic link (only for `lstat`)?
export isSymlink : Stat -> Bool
isSymlink st = fileType st == S_IFLNK
||| Is it a character device?
export isCharDevice : Stat -> Bool
isCharDevice st = fileType st == S_IFCHR
||| Is it a block device?
export isBlockDevice : Stat -> Bool
isBlockDevice st = fileType st == S_IFBLK
||| Is it a FIFO?
export isFifo : Stat -> Bool
isFifo st = fileType st == S_IFIFO
||| Is it a socket?
export isSocket : Stat -> Bool
isSocket st = fileType st == S_IFSOCK

%inline %foreign "CExpr:(sizeof(struct stat)),libc,sys/stat.h"
prim__sizeofStat : Int

%inline %foreign "CExpr:(((struct stat *)($1))->st_dev),libc,sys/stat.h"
prim__get_st_dev : AnyPtr -> PrimIO Bits64
%inline %foreign "CExpr:(((struct stat *)($1))->st_ino),libc,sys/stat.h"
prim__get_st_ino : AnyPtr -> PrimIO Bits64
%inline %foreign "CExpr:(((struct stat *)($1))->st_mode),libc,sys/stat.h"
prim__get_st_mode : AnyPtr -> PrimIO Bits32
%inline %foreign "CExpr:(((struct stat *)($1))->st_nlink),libc,sys/stat.h"
prim__get_st_nlink : AnyPtr -> PrimIO Bits64
%inline %foreign "CExpr:(((struct stat *)($1))->st_uid),libc,sys/stat.h"
prim__get_st_uid : AnyPtr -> PrimIO Bits32
%inline %foreign "CExpr:(((struct stat *)($1))->st_gid),libc,sys/stat.h"
prim__get_st_gid : AnyPtr -> PrimIO Bits32
%inline %foreign "CExpr:(((struct stat *)($1))->st_rdev),libc,sys/stat.h"
prim__get_st_rdev : AnyPtr -> PrimIO Bits64
%inline %foreign "CExpr:(((struct stat *)($1))->st_size),libc,sys/stat.h"
prim__get_st_size : AnyPtr -> PrimIO Int64
%inline %foreign "CExpr:(((struct stat *)($1))->st_blksize),libc,sys/stat.h"
prim__get_st_blksize : AnyPtr -> PrimIO Int64
%inline %foreign "CExpr:(((struct stat *)($1))->st_blocks),libc,sys/stat.h"
prim__get_st_blocks : AnyPtr -> PrimIO Int64
%inline %foreign "CExpr:(&((struct stat *)($1))->st_atim),libc,sys/stat.h"
prim__st_atim : AnyPtr -> PrimIO AnyPtr
%inline %foreign "CExpr:(&((struct stat *)($1))->st_mtim),libc,sys/stat.h"
prim__st_mtim : AnyPtr -> PrimIO AnyPtr
%inline %foreign "CExpr:(&((struct stat *)($1))->st_ctim),libc,sys/stat.h"
prim__st_ctim : AnyPtr -> PrimIO AnyPtr

readStat : AnyPtr -> IO Stat
readStat p = do
  dev <- primIO (prim__get_st_dev p)
  ino <- primIO (prim__get_st_ino p)
  mode <- primIO (prim__get_st_mode p)
  nlink <- primIO (prim__get_st_nlink p)
  uid <- primIO (prim__get_st_uid p)
  gid <- primIO (prim__get_st_gid p)
  rdev <- primIO (prim__get_st_rdev p)
  size <- primIO (prim__get_st_size p)
  blksize <- primIO (prim__get_st_blksize p)
  blocks <- primIO (prim__get_st_blocks p)
  at <- primIO (prim__st_atim p) >>= readTimeSpec
  mt <- primIO (prim__st_mtim p) >>= readTimeSpec
  ct <- primIO (prim__st_ctim p) >>= readTimeSpec
  pure (MkStat dev ino mode nlink uid gid rdev size blksize blocks at mt ct)

statWith : (AnyPtr -> PrimIO Int32) -> IO (Either Errno Stat)
statWith call = do
  p <- malloc prim__sizeofStat
  r <- primIO (call p)
  res <- if r == 0 then Right <$> readStat p else Left <$> errno
  free p
  pure res

%inline %foreign "CExpr:(stat($1, (struct stat *)($2))),libc,sys/stat.h"
prim__stat : String -> AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(lstat($1, (struct stat *)($2))),libc,sys/stat.h"
prim__lstat : String -> AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(fstat($1, (struct stat *)($2))),libc,sys/stat.h"
prim__fstat : Bits32 -> AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(fstatat($1, $2, (struct stat *)($3), $4)),libc,fcntl.h;sys/stat.h"
prim__fstatat : Int32 -> String -> AnyPtr -> Bits32 -> PrimIO Int32

||| The status of a file, following symbolic links.
export
stat : String -> IO (Either Errno Stat)
stat path = statWith (prim__stat path)

||| The status of a file; a symbolic link is described itself.
export
lstat : String -> IO (Either Errno Stat)
lstat path = statWith (prim__lstat path)

||| The status of an open file.
export
fstat : FileDesc -> IO (Either Errno Stat)
fstat fd = statWith (prim__fstat fd.rawfd)

%inline %foreign "CExpr:(AT_FDCWD),libc,fcntl.h"
prim__AT_FDCWD : Int32

||| The status of a path relative to a directory descriptor (the current
||| directory for `Nothing`). `flags` is 0 or `AT_SYMLINK_NOFOLLOW`.
export
fstatat : Maybe DirDesc -> String -> (flags : Bits32) -> IO (Either Errno Stat)
fstatat dir path flags =
  let d = maybe prim__AT_FDCWD (\x => cast x.rawdirfd) dir
  in statWith (\p => prim__fstatat d path p flags)

-------------------------------------------------------------------------------
-- access

||| `access` mode: the file exists.
%inline %foreign "CExpr:(F_OK),libc,unistd.h"
export F_OK : Bits32
||| `access` mode: read permission.
%inline %foreign "CExpr:(R_OK),libc,unistd.h"
export R_OK : Bits32
||| `access` mode: write permission.
%inline %foreign "CExpr:(W_OK),libc,unistd.h"
export W_OK : Bits32
||| `access` mode: execute (search) permission.
%inline %foreign "CExpr:(X_OK),libc,unistd.h"
export X_OK : Bits32

%inline %foreign "CExpr:(access($1, $2)),libc,unistd.h"
prim__access : String -> Bits32 -> PrimIO Int32

||| Check the calling process's permissions on a path with its real user and
||| group IDs. `mode` is `F_OK` or an `or` of `R_OK`, `W_OK`, `X_OK`.
export
access : String -> (mode : Bits32) -> IO (Either Errno ())
access path mode = primIO (prim__access path mode) >>= checkUnit

-------------------------------------------------------------------------------
-- truncate / umask

%inline %foreign "CExpr:(truncate($1, $2)),libc,unistd.h;sys/types.h"
prim__truncate : String -> Int64 -> PrimIO Int32
%inline %foreign "CExpr:(ftruncate($1, $2)),libc,unistd.h;sys/types.h"
prim__ftruncate : Bits32 -> Int64 -> PrimIO Int32

||| Set the size of a file given by path.
export
truncate : String -> (length : Int64) -> IO (Either Errno ())
truncate path len = primIO (prim__truncate path len) >>= checkUnit

||| Set the size of an open file.
export
ftruncate : FileDesc -> (length : Int64) -> IO (Either Errno ())
ftruncate fd len = primIO (prim__ftruncate fd.rawfd len) >>= checkUnit

%inline %foreign "CExpr:(umask($1)),libc,sys/stat.h"
prim__umask : Bits32 -> PrimIO Bits32

||| Set the file mode creation mask and return the previous one.
export
umask : Bits32 -> IO Bits32
umask m = primIO (prim__umask m)

-------------------------------------------------------------------------------
-- utimensat

%inline %foreign "CExpr:(UTIME_NOW),libc,fcntl.h;sys/stat.h"
prim__UTIME_NOW : Int64
%inline %foreign "CExpr:(UTIME_OMIT),libc,fcntl.h;sys/stat.h"
prim__UTIME_OMIT : Int64

||| What `utimensat` does with one of the two times.
public export
data SetTime = SetNow | Omit | SetTo TimeSpec

setTimeSpec : SetTime -> TimeSpec
setTimeSpec SetNow = MkTimeSpec 0 prim__UTIME_NOW
setTimeSpec Omit = MkTimeSpec 0 prim__UTIME_OMIT
setTimeSpec (SetTo t) = t

%inline %foreign "CExpr:(utimensat($1, $2, (struct timespec *)($3), $4)),libc,fcntl.h;sys/stat.h"
prim__utimensat : Int32 -> String -> AnyPtr -> Bits32 -> PrimIO Int32
%inline %foreign "CExpr:(((struct timespec *)($1)) + 1),libc,time.h"
prim__nextTimeSpec : AnyPtr -> PrimIO AnyPtr

||| Set the access and modification times of a path (relative to a
||| directory descriptor, or to the current directory for `Nothing`). `flags`
||| is 0 or `AT_SYMLINK_NOFOLLOW`.
export
utimensat : Maybe DirDesc -> String -> (atime : SetTime) -> (mtime : SetTime) -> (flags : Bits32)
         -> IO (Either Errno ())
utimensat dir path at mt flags = do
  p <- malloc (2 * prim__sizeofTimespec)
  writeTimeSpec p (setTimeSpec at)
  q <- primIO (prim__nextTimeSpec p)
  writeTimeSpec q (setTimeSpec mt)
  let d = maybe prim__AT_FDCWD (\x => cast x.rawdirfd) dir
  r <- primIO (prim__utimensat d path p flags)
  res <- checkUnit r
  free p
  pure res
