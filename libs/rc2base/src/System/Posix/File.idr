||| POSIX file operations: `open`/`creat`/`openat`, `dup*`, `lseek`, reads,
||| writes, locks and the `O_*` flags.
|||
||| Build flags: a few declarations here (and `preadv2`/`pwritev2` in
||| `System.Posix.Uio`) are Linux extensions that glibc only declares under
||| `_GNU_SOURCE`: `O_DIRECT`, `O_LARGEFILE`, `O_NOATIME`, `O_PATH`,
||| `O_TMPFILE`, `AT_EMPTY_PATH`, `SEEK_DATA`, `SEEK_HOLE` and `dup3`.
||| A program that uses one must be built with
||| `IDRIS2_CFLAGS=-D_GNU_SOURCE` (or `CFLAGS=-D_GNU_SOURCE`) in the
||| environment of the Idris compiler; otherwise the generated C does not
||| compile. Each such declaration carries a one-line note pointing here.
module System.Posix.File

import Data.Buffer
import Data.Buffer.RC2
import Data.String
import Data.String.RC2
import System.Posix.Errno
import public System.Posix.FileDesc
import System.FFI

-------------------------------------------------------------------------------
--
||| File open flag: append writes at the end of the file.
%inline %foreign "CExpr:(O_APPEND),libc,fcntl.h;sys/stat.h;sys/types.h"
export O_APPEND : Bits32
||| File open flag: send signal when file is ready for I/O.
%inline %foreign "CExpr:(O_ASYNC),libc,fcntl.h;sys/stat.h;sys/types.h"
export O_ASYNC : Bits32
||| File open flag: close descriptor on exec.
%inline %foreign "CExpr:(O_CLOEXEC),libc,fcntl.h;sys/stat.h;sys/types.h"
export O_CLOEXEC : Bits32
||| File open flag: create the file if it does not exist.
%inline %foreign "CExpr:(O_CREAT),libc,fcntl.h;sys/stat.h;sys/types.h"
export O_CREAT : Bits32
||| File open flag: avoid cached data on the file.
|||
||| Needs `_GNU_SOURCE` (a Linux extension, not POSIX); see "Build flags" in the `System.Posix.File` header.
%inline %foreign "CExpr:(O_DIRECT),libc,fcntl.h;sys/stat.h;sys/types.h"
export O_DIRECT : Bits32
||| File open flag: require the path to be a directory.
%inline %foreign "CExpr:(O_DIRECTORY),libc,fcntl.h;sys/stat.h;sys/types.h"
export O_DIRECTORY : Bits32
||| File open flag: synchronous data writes.
%inline %foreign "CExpr:(O_DSYNC),libc,fcntl.h;sys/stat.h;sys/types.h"
export O_DSYNC : Bits32
||| File open flag: fail if the file already exists.
%inline %foreign "CExpr:(O_EXCL),libc,fcntl.h;sys/stat.h;sys/types.h"
export O_EXCL : Bits32
||| File open flag: allow large files.
|||
||| Needs `_GNU_SOURCE` (a Linux extension, not POSIX); see "Build flags" in the `System.Posix.File` header.
%inline %foreign "CExpr:(O_LARGEFILE),libc,fcntl.h;sys/stat.h;sys/types.h"
export O_LARGEFILE : Bits32
||| File open flag: do not update access time.
|||
||| Needs `_GNU_SOURCE` (a Linux extension, not POSIX); see "Build flags" in the `System.Posix.File` header.
%inline %foreign "CExpr:(O_NOATIME),libc,fcntl.h;sys/stat.h;sys/types.h"
export O_NOATIME : Bits32
||| File open flag: do not assign controlling terminal.
%inline %foreign "CExpr:(O_NOCTTY),libc,fcntl.h;sys/stat.h;sys/types.h"
export O_NOCTTY : Bits32
||| File open flag: do not follow symbolic links.
%inline %foreign "CExpr:(O_NOFOLLOW),libc,fcntl.h;sys/stat.h;sys/types.h"
export O_NOFOLLOW : Bits32
||| File open flag: open in non-blocking mode.
%inline %foreign "CExpr:(O_NONBLOCK),libc,fcntl.h;sys/stat.h;sys/types.h"
export O_NONBLOCK : Bits32
||| File open flag: open the path as a file descriptor to the object itself.
|||
||| Needs `_GNU_SOURCE` (a Linux extension, not POSIX); see "Build flags" in the `System.Posix.File` header.
%inline %foreign "CExpr:(O_PATH),libc,fcntl.h;sys/stat.h;sys/types.h"
export O_PATH : Bits32
||| File open flag: synchronous file content writes.
%inline %foreign "CExpr:(O_SYNC),libc,fcntl.h;sys/stat.h;sys/types.h"
export O_SYNC : Bits32
||| File open flag: create a temporary unnamed file.
|||
||| Needs `_GNU_SOURCE` (a Linux extension, not POSIX); see "Build flags" in the `System.Posix.File` header.
%inline %foreign "CExpr:(O_TMPFILE),libc,fcntl.h;sys/stat.h;sys/types.h"
export O_TMPFILE : Bits32
||| File open flag: truncate the file on open.
%inline %foreign "CExpr:(O_TRUNC),libc,fcntl.h;sys/stat.h;sys/types.h"
export O_TRUNC : Bits32

||| Directory entry flag: do not follow a symbolic link.
%inline %foreign "CExpr:(AT_SYMLINK_NOFOLLOW),libc,fcntl.h;sys/stat.h"
export AT_SYMLINK_NOFOLLOW : Bits32
||| Directory entry flag: open the empty path to the directory itself.
|||
||| Needs `_GNU_SOURCE` (a Linux extension, not POSIX); see "Build flags" in the `System.Posix.File` header.
%inline %foreign "CExpr:(AT_EMPTY_PATH),libc,fcntl.h;sys/stat.h"
export AT_EMPTY_PATH : Bits32


-------------------------------------------------------------------------------
-- File open


%inline %foreign "CExpr:(open($1, $2, $3)),libc,fcntl.h;sys/stat.h;sys/types.h"
prim__open : String -> Bits32 -> Bits32 -> PrimIO Int32

||| Open a file at `pathname` using the given flags and mode.
public export
openFile : String -> Bits32 -> Bits32 -> IO (Either Errno FileDesc)
openFile pathname flags mode =
  primIO (prim__open pathname flags mode) >>= primFdToFileDesc



%inline %foreign "CExpr:(creat($1, $2)),libc,fcntl.h;sys/stat.h;sys/types.h"
prim__creat : String -> Bits32 -> PrimIO Int32

||| Create and open a new file with the requested permissions.
public export
creat : String -> Bits32 -> IO (Either Errno FileDesc)
creat pathname mode =
  primIO (prim__creat pathname mode) >>= primFdToFileDesc


%inline %foreign "CExpr:(openat($1, $2, $3, $4)),libc,fcntl.h;sys/stat.h;sys/types.h"
prim__openat : Bits32 -> String -> Bits32 -> Bits32 -> PrimIO Int32

||| Open a file relative to a directory descriptor.
public export
openat : DirDesc -> String -> Bits32 -> Bits32 -> IO (Either Errno FileDesc)
openat dirfd  pathname flags mode =
  primIO (prim__openat dirfd.rawdirfd pathname flags mode)
    >>= primFdToFileDesc

-- OpenHow : Type
-- OpenHow = Struct "open_how" [("flags", Bits32), ("resolve", Bits32)]
-- %inline %foreign "CExpr:(cmalloc(sizeof(struct open_how), 1)),libc,sys/types.h,sys/stat.h,sys/fcntl.h,stdlib.h"
-- prim_newOpenHow : PrimIO OpenHow
--
-- %inline %foreign "CExpr:(openat2($1, $2, $3, $4)),libc,fcntl.h;sys/stat.h;sys/types.h"
-- prim_openat2 : Bits32 -> String -> OpenHow -> Int64 -> PrimIO Int32



-------------------------------------------------------------------------------
-- read/write

namespace String
  -- %inline %foreign "CExpr:(read($1, $2, $3)),libc,unistd.h"
  -- prim__read : Bits32 -> String -> Bits64 -> PrimIO Int64
  %inline %foreign "CExpr:(write($1, $2, $3)),libc,unistd.h"
  prim__write : Bits32 -> String -> Bits64 -> PrimIO Int64

  -- %inline public export
  -- read : FileDesc -> Bits32 -> IO (Maybe String)
  -- read fd count = do

  ||| Write a UTF-8 string to a file descriptor.
  %inline public export
  write : FileDesc -> String -> IO Int64
  write fd str =
    primIO $ prim__write fd.rawfd str $ cast{to=Bits64} $ byteLength str



namespace AnyPtr
  %inline %foreign "CExpr:(read($1, $2, $3)),libc,unistd.h"
  prim__read : Bits32 -> AnyPtr -> Bits64 -> PrimIO Int64
  %inline %foreign "CExpr:(write($1, $2, $3)),libc,unistd.h"
  prim__write : Bits32 -> AnyPtr -> Bits64 -> PrimIO Int64

  ||| Read up to `count` bytes from a file descriptor into memory.
  %inline public export
  read : FileDesc -> AnyPtr -> Bits64 -> IO Int64
  read fd buf count = primIO (prim__read fd.rawfd buf count)

  ||| Write up to `count` bytes from memory to a file descriptor.
  %inline public export
  write : FileDesc -> AnyPtr -> Bits64 -> IO Int64
  write fd buf count = primIO (prim__write fd.rawfd buf count)



namespace Buffer
  %inline %foreign "CExpr:(read($1, $2, $3)),libc,unistd.h"
  prim__read : Bits32 -> Buffer -> Bits64 -> PrimIO Int64
  %inline %foreign "CExpr:(write($1, $2, $3)),libc,unistd.h"
  prim__write : Bits32 -> Buffer -> Bits64 -> PrimIO Int64

  ||| Read the entire buffer from a file descriptor.
  %inline public export
  read : FileDesc -> Buffer -> IO Int64
  read fd buf =
    primIO $ prim__read fd.rawfd buf $ cast{to=Bits64} !(rawSize buf)

  ||| Write the entire buffer to a file descriptor.
  %inline public export
  write : FileDesc -> Buffer -> IO Int64
  write fd buf =
    primIO $ prim__write fd.rawfd buf $ cast{to=Bits64} !(rawSize buf)


-------------------------------------------------------------------------------
-- lseek

||| An offset used with `lseek` and file-allocation operations.
export
data FileOffset = MkFileOffset Int64

export
Cast a Int64 => Cast a FileOffset where cast x = MkFileOffset $ cast x


%inline %foreign "CExpr:(SEEK_SET),libc,sys/types.h;unistd.h"
prim__SEEK_SET : Bits32
%inline %foreign "CExpr:(SEEK_CUR),libc,sys/types.h;unistd.h"
prim__SEEK_CUR : Bits32
%inline %foreign "CExpr:(SEEK_END),libc,sys/types.h;unistd.h"
prim__SEEK_END : Bits32
%inline %foreign "CExpr:(SEEK_DATA),libc,sys/types.h;unistd.h"
prim__SEEK_DATA : Bits32
%inline %foreign "CExpr:(SEEK_HOLE),libc,sys/types.h;unistd.h"
prim__SEEK_HOLE : Bits32

||| The reference point for a seek operation.
public export
data SeekWhence = MkSeekWhence Bits32

||| Seek from the start of the file.
public export
SEEK_SET : SeekWhence
SEEK_SET = MkSeekWhence prim__SEEK_SET

||| Seek relative to the current file offset.
public export
SEEK_CUR : SeekWhence
SEEK_CUR = MkSeekWhence prim__SEEK_CUR

||| Seek relative to the end of the file.
public export
SEEK_END : SeekWhence
SEEK_END = MkSeekWhence prim__SEEK_END

||| Seek to the next data location after the current offset.
|||
||| Needs `_GNU_SOURCE` (a Linux extension, not POSIX); see "Build flags" in the `System.Posix.File` header.
public export
SEEK_DATA : SeekWhence
SEEK_DATA = MkSeekWhence prim__SEEK_DATA

||| Seek to the next hole after the current offset.
|||
||| Needs `_GNU_SOURCE` (a Linux extension, not POSIX); see "Build flags" in the `System.Posix.File` header.
public export
SEEK_HOLE : SeekWhence
SEEK_HOLE = MkSeekWhence prim__SEEK_HOLE

-- TODO: off_tが32bitだった場合の対応
%inline %foreign "CExpr:(lseek($1, $2, $3)),libc,sys/types.h;unistd.h"
prim__lseekSet : Bits32 -> Int64 -> Bits32 -> PrimIO Int64

||| Move the file offset of a file descriptor relative to a seek origin.
%inline public export
lseek : FileDesc -> FileOffset -> SeekWhence -> IO Int64
lseek fd (MkFileOffset offset) (MkSeekWhence whence) =
  primIO $ prim__lseekSet fd.rawfd offset whence


-------------------------------------------------------------------------------
-- fallocate

%inline %foreign "CExpr:(posix_fallocate($1, $2, $3)),libc,fcntl.h"
prim__fallocate : Bits32 -> Int64 -> Int64 -> PrimIO Int32

||| Reserve space for a file region without modifying the file contents.
%inline public export
fallocate : FileDesc -> FileOffset -> FileOffset -> IO Int32
fallocate fd (MkFileOffset offset) (MkFileOffset len) =
  primIO $ prim__fallocate fd.rawfd offset len



-------------------------------------------------------------------------------
-- chmod

%inline %foreign "CExpr:(chmod($1, $2)),libc,sys/stat.h"
prim__chmod : String -> Bits32 -> PrimIO Int32

||| Change the permissions of a file path.
%inline public export
chmod : String -> Bits32 -> IO Int32
chmod filename mode = primIO $ prim__chmod filename mode


%inline %foreign "CExpr:(fchmod($1, $2)),libc,sys/stat.h"
prim__fchmod : Bits32  -> Bits32 -> PrimIO Int32

||| Change the permissions of an open file descriptor.
%inline public export
fchmod : FileDesc -> Bits32 -> IO Int32
fchmod fd mode = primIO $ prim__fchmod fd.rawfd mode



%inline %foreign "CExpr:(fchmodat($1, $2, $3, $4)),libc,fcntl.h;sys/stat.h"
prim__fchmodat : Bits32  -> String -> Bits32 -> Bits32 -> PrimIO Int32

||| Change the permissions of a path relative to a directory descriptor.
%inline public export
fchmodat : DirDesc -> String -> Bits32 -> Bits32 -> IO Int32
fchmodat dirfd pathname mode flags =
  primIO $ prim__fchmodat dirfd.rawdirfd pathname mode flags



-------------------------------------------------------------------------------
-- chown

%inline %foreign "CExpr:(chown($1, $2, $3)),libc,unistd.h"
prim__chown : String -> Bits32 -> Bits32 -> PrimIO Int32

||| Change the owner of a path.
%inline public export
chown : String -> Bits32 -> Bits32 -> IO Int32
chown filename owner group = primIO $ prim__chown filename owner group

%inline %foreign "CExpr:(fchown($1, $2, $3)),libc,unistd.h"
prim__fchown : Bits32 -> Bits32 -> Bits32 -> PrimIO Int32

||| Change the owner of an open file descriptor.
%inline public export
fchown : FileDesc -> Bits32 -> Bits32 -> IO Int32
fchown fd owner group = primIO $ prim__fchown fd.rawfd owner group

%inline %foreign "CExpr:(lchown($1, $2, $3)),libc,unistd.h"
prim__lchown : String -> Bits32 -> Bits32 -> PrimIO Int32

||| Change the owner of a symbolic link path.
%inline public export
lchown : String -> Bits32 -> Bits32 -> IO Int32
lchown filename owner group = primIO $ prim__lchown filename owner group


%inline %foreign "CExpr:(fchownat($1, $2, $3, $4, $5)),libc,fcntl.h;unistd.h"
prim__fchownat : Bits32  -> String -> Bits32 -> Bits32 -> Bits32 -> PrimIO Int32

||| Change the owner of a path relative to a directory descriptor.
%inline public export
fchownat : DirDesc -> String -> Bits32 -> Bits32 -> Bits32 -> IO Int32
fchownat dirfd pathname owner group flags =
  primIO $ prim__fchownat dirfd.rawdirfd pathname owner group flags



-------------------------------------------------------------------------------
-- flock / funlock

%inline %foreign "CExpr:(flock($1, LOCK_SH)),libc,sys/file.h"
prim__flockShared : Bits32 -> PrimIO Int32
%inline %foreign "CExpr:(flock($1, LOCK_EX)),libc,sys/file.h"
prim__flockExclude : Bits32 -> PrimIO Int32
%inline %foreign "CExpr:(flock($1, LOCK_UN)),libc,sys/file.h"
prim__funlock : Bits32 -> PrimIO Int32

||| Acquire a shared lock on a file descriptor.
%inline public export
flockShared : FileDesc -> IO Int32
flockShared fd = primIO $ prim__flockShared fd.rawfd

||| Acquire an exclusive lock on a file descriptor.
%inline public export
flockExclude : FileDesc -> IO Int32
flockExclude fd = primIO $ prim__flockExclude fd.rawfd

||| Release a file lock held by the current process.
%inline public export
funlock : FileDesc -> IO Int32
funlock fd = primIO $ prim__funlock fd.rawfd


-------------------------------------------------------------------------------
-- locf

%inline %foreign "CExpr:(lockf($1, F_LOCK, $2)),libc,unistd.h"
prim__lockf : Bits32 -> Int64 -> PrimIO Int32
%inline %foreign "CExpr:(lockf($1, F_TLOCK, $2)),libc,unistd.h"
prim__lockfTestAndLock : Bits32 -> Int64 -> PrimIO Int32
%inline %foreign "CExpr:(lockf($1, F_ULOCK, $2)),libc,unistd.h"
prim__lockfUnlock : Bits32 -> Int64 -> PrimIO Int32
%inline %foreign "CExpr:(lockf($1, F_TEST, $2)),libc,unistd.h"
prim__lockfTest : Bits32 -> Int64 -> PrimIO Int32

||| Lock a file region.
%inline public export
lockf : FileDesc -> Int64 -> IO Int32
lockf fd len = primIO (prim__lockf fd.rawfd len)

||| Test and lock a file region non-blockingly.
%inline public export
lockfTestAndLock : FileDesc -> Int64 -> IO Int32
lockfTestAndLock fd len = primIO (prim__lockfTestAndLock fd.rawfd len)

||| Unlock a file region.
%inline public export
lockfUnlock : FileDesc -> Int64 -> IO Int32
lockfUnlock fd len = primIO (prim__lockfUnlock fd.rawfd len)

||| Test whether a file region is locked.
%inline public export
lockfTest : FileDesc -> Int64 -> IO Int32
lockfTest fd len = primIO (prim__lockfTest fd.rawfd len)


-------------------------------------------------------------------------------
-- dup


%inline %foreign "CExpr:(dup($1)),libc,unistd.h"
prim__dup : Bits32 -> PrimIO Int32
%inline %foreign "CExpr:(dup2($1, $2)),libc,unistd.h"
prim__dup2 : Bits32 -> Bits32 -> PrimIO Int32
%inline %foreign "CExpr:(dup3($1, $2, $3)),libc,fcntl.h;unistd.h"
prim__dup3 : Bits32 -> Bits32 -> Bits32 -> PrimIO Int32

||| Duplicate a file descriptor onto the lowest free number.
|||
||| See also: `dup(2)`.
%inline public export
dup : FileDesc -> IO (Either Errno FileDesc)
dup fd = primIO (prim__dup fd.rawfd) >>= primFdToFileDesc

||| Duplicate a file descriptor onto the given number, closing it first if open.
|||
||| See also: `dup(2)`; `dup3` for the Linux variant taking flags.
%inline public export
dup2 : FileDesc -> FileDesc -> IO (Either Errno FileDesc)
dup2 oldfd newfd = primIO (prim__dup2 oldfd.rawfd newfd.rawfd) >>= primFdToFileDesc


||| `dup3`.
|||
||| Needs `_GNU_SOURCE` (a Linux extension, not POSIX); see "Build flags" in the `System.Posix.File` header.
%inline public export
dup3 : FileDesc -> FileDesc -> Bits32 -> IO (Either Errno FileDesc)
dup3 oldfd newfd flags =
  primIO (prim__dup3 oldfd.rawfd newfd.rawfd flags) >>= primFdToFileDesc



-------------------------------------------------------------------------------
-- fcntl

-- cannt be supported due to varargs.


-------------------------------------------------------------------------------
-- sync/fsync

%inline %foreign "CExpr:(sync()),libc,unistd.h"
prim__sync : PrimIO ()
||| Synchronize all in-core file system state with storage device.
%inline public export
sync : IO ()
sync = primIO prim__sync

%inline %foreign "CExpr:(fsync($1)),libc,unistd.h"
prim__fsync : Bits32 -> PrimIO Int32
||| Synchronize a file's in-core state with storage device.
%inline public export
fsync : FileDesc -> IO Int32
fsync fd = primIO $ prim__fsync fd.rawfd


%inline %foreign "CExpr:(fdatasync($1)),libc,unistd.h"
prim__fdatasync : Bits32 -> PrimIO Int32
||| Synchronize a file's in-core data with storage device.
%inline public export
fdatasync : FileDesc -> IO Int32
fdatasync fd = primIO $ prim__fdatasync fd.rawfd

