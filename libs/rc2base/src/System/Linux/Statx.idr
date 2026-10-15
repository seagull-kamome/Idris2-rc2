||| `statx`: file status with the birth time, the mount ID and the file
||| attributes, and a mask that says which of the fields the file system filled in.
|||
||| Linux only. `statx` and its constants are declared by glibc only under
||| `_GNU_SOURCE`: build with `IDRIS2_CFLAGS=-D_GNU_SOURCE`. `struct statx` is copied
||| into the record `Statx` at once, so no C struct is visible to the caller.
module System.Linux.Statx

import Data.Bits
import System.FFI
import System.Posix.Errno
import System.Posix.File
import System.Posix.FileDesc
import System.Posix.Time

%default total

||| An `or` of `STATX_*` bits: the fields asked for, and in `Statx.mask` the
||| fields that are valid.
public export
StatxMask : Type
StatxMask = Bits32

||| The file type bits of `mode`.
%inline %foreign "CExpr:(STATX_TYPE),libc,sys/stat.h;fcntl.h"
export STATX_TYPE : StatxMask
||| The permission bits of `mode`.
%inline %foreign "CExpr:(STATX_MODE),libc,sys/stat.h;fcntl.h"
export STATX_MODE : StatxMask
||| `nlink`.
%inline %foreign "CExpr:(STATX_NLINK),libc,sys/stat.h;fcntl.h"
export STATX_NLINK : StatxMask
||| `uid`.
%inline %foreign "CExpr:(STATX_UID),libc,sys/stat.h;fcntl.h"
export STATX_UID : StatxMask
||| `gid`.
%inline %foreign "CExpr:(STATX_GID),libc,sys/stat.h;fcntl.h"
export STATX_GID : StatxMask
||| `atime`.
%inline %foreign "CExpr:(STATX_ATIME),libc,sys/stat.h;fcntl.h"
export STATX_ATIME : StatxMask
||| `mtime`.
%inline %foreign "CExpr:(STATX_MTIME),libc,sys/stat.h;fcntl.h"
export STATX_MTIME : StatxMask
||| `ctime`.
%inline %foreign "CExpr:(STATX_CTIME),libc,sys/stat.h;fcntl.h"
export STATX_CTIME : StatxMask
||| `ino`.
%inline %foreign "CExpr:(STATX_INO),libc,sys/stat.h;fcntl.h"
export STATX_INO : StatxMask
||| `size`.
%inline %foreign "CExpr:(STATX_SIZE),libc,sys/stat.h;fcntl.h"
export STATX_SIZE : StatxMask
||| `blocks`.
%inline %foreign "CExpr:(STATX_BLOCKS),libc,sys/stat.h;fcntl.h"
export STATX_BLOCKS : StatxMask
||| All the fields `stat` gives.
%inline %foreign "CExpr:(STATX_BASIC_STATS),libc,sys/stat.h;fcntl.h"
export STATX_BASIC_STATS : StatxMask
||| `btime`, the birth time (not every file system has it).
%inline %foreign "CExpr:(STATX_BTIME),libc,sys/stat.h;fcntl.h"
export STATX_BTIME : StatxMask
||| `mnt_id` (Linux 5.8).
%inline %foreign "CExpr:(STATX_MNT_ID),libc,sys/stat.h;fcntl.h"
export STATX_MNT_ID : StatxMask

||| Sync flags for `statx` (an `or` with `AT_SYMLINK_NOFOLLOW` / `AT_EMPTY_PATH`).
||| The default is `AT_STATX_SYNC_AS_STAT`.
%inline %foreign "CExpr:(AT_STATX_SYNC_AS_STAT),libc,sys/stat.h;fcntl.h"
export AT_STATX_SYNC_AS_STAT : Bits32
||| Ask a network file system's server for fresh values.
%inline %foreign "CExpr:(AT_STATX_FORCE_SYNC),libc,sys/stat.h;fcntl.h"
export AT_STATX_FORCE_SYNC : Bits32
||| Take the values the client has cached.
%inline %foreign "CExpr:(AT_STATX_DONT_SYNC),libc,sys/stat.h;fcntl.h"
export AT_STATX_DONT_SYNC : Bits32

||| The fields of `struct statx`. A field is valid only if its bit is in `mask`
||| (`stxBtime` may be zero on a file system without birth times; `stxMntId` is valid
||| only with `STATX_MNT_ID`, which needs Linux 5.8 and a glibc that has `stx_mnt_id`,
||| 2.37 or later). The device numbers are split into a major and a minor.
public export
record Statx where
  constructor MkStatx
  stxMask : StatxMask
  stxBlksize : Bits32
  stxAttributes : Bits64
  stxNlink : Bits32
  stxUid : Bits32
  stxGid : Bits32
  stxMode : Bits16
  stxIno : Bits64
  stxSize : Bits64
  stxBlocks : Bits64
  stxAttributesMask : Bits64
  stxAtime : TimeSpec
  stxBtime : TimeSpec
  stxCtime : TimeSpec
  stxMtime : TimeSpec
  stxRdevMajor : Bits32
  stxRdevMinor : Bits32
  stxDevMajor : Bits32
  stxDevMinor : Bits32
  stxMntId : Bits64

export
Show Statx where
  show s = "Statx mask=" ++ show s.stxMask ++ " mode=" ++ show s.stxMode ++ " nlink=" ++ show s.stxNlink
        ++ " uid=" ++ show s.stxUid ++ " gid=" ++ show s.stxGid ++ " size=" ++ show s.stxSize
        ++ " mtime=" ++ show s.stxMtime

||| Whether all the bits of `want` are set in the mask `have`.
export
hasMask : (want : StatxMask) -> (have : StatxMask) -> Bool
hasMask want have = (have .&. want) == want

%inline %foreign "CExpr:(sizeof(struct statx)),libc,sys/stat.h;fcntl.h"
prim__sizeofStatx : Int
%inline %foreign "CExpr:(AT_FDCWD),libc,fcntl.h"
prim__AT_FDCWD : Int32
%inline %foreign "CExpr:(statx($1, $2, $3, $4, (struct statx *)($5))),libc,sys/stat.h;fcntl.h"
prim__statx : Int32 -> String -> Bits32 -> StatxMask -> AnyPtr -> PrimIO Int32

%inline %foreign "CExpr:(((struct statx *)($1))->stx_mask),libc,sys/stat.h;fcntl.h"
prim__mask : AnyPtr -> PrimIO Bits32
%inline %foreign "CExpr:(((struct statx *)($1))->stx_blksize),libc,sys/stat.h;fcntl.h"
prim__blksize : AnyPtr -> PrimIO Bits32
%inline %foreign "CExpr:(((struct statx *)($1))->stx_attributes),libc,sys/stat.h;fcntl.h"
prim__attributes : AnyPtr -> PrimIO Bits64
%inline %foreign "CExpr:(((struct statx *)($1))->stx_nlink),libc,sys/stat.h;fcntl.h"
prim__nlink : AnyPtr -> PrimIO Bits32
%inline %foreign "CExpr:(((struct statx *)($1))->stx_uid),libc,sys/stat.h;fcntl.h"
prim__uid : AnyPtr -> PrimIO Bits32
%inline %foreign "CExpr:(((struct statx *)($1))->stx_gid),libc,sys/stat.h;fcntl.h"
prim__gid : AnyPtr -> PrimIO Bits32
%inline %foreign "CExpr:(((struct statx *)($1))->stx_mode),libc,sys/stat.h;fcntl.h"
prim__mode : AnyPtr -> PrimIO Bits16
%inline %foreign "CExpr:(((struct statx *)($1))->stx_ino),libc,sys/stat.h;fcntl.h"
prim__ino : AnyPtr -> PrimIO Bits64
%inline %foreign "CExpr:(((struct statx *)($1))->stx_size),libc,sys/stat.h;fcntl.h"
prim__size : AnyPtr -> PrimIO Bits64
%inline %foreign "CExpr:(((struct statx *)($1))->stx_blocks),libc,sys/stat.h;fcntl.h"
prim__blocks : AnyPtr -> PrimIO Bits64
%inline %foreign "CExpr:(((struct statx *)($1))->stx_attributes_mask),libc,sys/stat.h;fcntl.h"
prim__attributes_mask : AnyPtr -> PrimIO Bits64
%inline %foreign "CExpr:(((struct statx *)($1))->stx_rdev_major),libc,sys/stat.h;fcntl.h"
prim__rdev_major : AnyPtr -> PrimIO Bits32
%inline %foreign "CExpr:(((struct statx *)($1))->stx_rdev_minor),libc,sys/stat.h;fcntl.h"
prim__rdev_minor : AnyPtr -> PrimIO Bits32
%inline %foreign "CExpr:(((struct statx *)($1))->stx_dev_major),libc,sys/stat.h;fcntl.h"
prim__dev_major : AnyPtr -> PrimIO Bits32
%inline %foreign "CExpr:(((struct statx *)($1))->stx_dev_minor),libc,sys/stat.h;fcntl.h"
prim__dev_minor : AnyPtr -> PrimIO Bits32
%inline %foreign "CExpr:(((struct statx *)($1))->stx_mnt_id),libc,sys/stat.h;fcntl.h"
prim__mnt_id : AnyPtr -> PrimIO Bits64
%inline %foreign "CExpr:(((struct statx *)($1))->stx_atime.tv_sec),libc,sys/stat.h;fcntl.h"
prim__atime_sec : AnyPtr -> PrimIO Int64
%inline %foreign "CExpr:(((struct statx *)($1))->stx_atime.tv_nsec),libc,sys/stat.h;fcntl.h"
prim__atime_nsec : AnyPtr -> PrimIO Bits32
%inline %foreign "CExpr:(((struct statx *)($1))->stx_btime.tv_sec),libc,sys/stat.h;fcntl.h"
prim__btime_sec : AnyPtr -> PrimIO Int64
%inline %foreign "CExpr:(((struct statx *)($1))->stx_btime.tv_nsec),libc,sys/stat.h;fcntl.h"
prim__btime_nsec : AnyPtr -> PrimIO Bits32
%inline %foreign "CExpr:(((struct statx *)($1))->stx_ctime.tv_sec),libc,sys/stat.h;fcntl.h"
prim__ctime_sec : AnyPtr -> PrimIO Int64
%inline %foreign "CExpr:(((struct statx *)($1))->stx_ctime.tv_nsec),libc,sys/stat.h;fcntl.h"
prim__ctime_nsec : AnyPtr -> PrimIO Bits32
%inline %foreign "CExpr:(((struct statx *)($1))->stx_mtime.tv_sec),libc,sys/stat.h;fcntl.h"
prim__mtime_sec : AnyPtr -> PrimIO Int64
%inline %foreign "CExpr:(((struct statx *)($1))->stx_mtime.tv_nsec),libc,sys/stat.h;fcntl.h"
prim__mtime_nsec : AnyPtr -> PrimIO Bits32

readTime : (AnyPtr -> PrimIO Int64) -> (AnyPtr -> PrimIO Bits32) -> AnyPtr -> IO TimeSpec
readTime sec nsec p = do
  s <- primIO (sec p)
  n <- primIO (nsec p)
  pure (MkTimeSpec s (cast n))

readStatx : AnyPtr -> IO Statx
readStatx p = do
  mask <- primIO (prim__mask p)
  blksize <- primIO (prim__blksize p)
  attributes <- primIO (prim__attributes p)
  nlink <- primIO (prim__nlink p)
  uid <- primIO (prim__uid p)
  gid <- primIO (prim__gid p)
  mode <- primIO (prim__mode p)
  ino <- primIO (prim__ino p)
  size <- primIO (prim__size p)
  blocks <- primIO (prim__blocks p)
  attributesMask <- primIO (prim__attributes_mask p)
  atime <- readTime prim__atime_sec prim__atime_nsec p
  btime <- readTime prim__btime_sec prim__btime_nsec p
  ctime <- readTime prim__ctime_sec prim__ctime_nsec p
  mtime <- readTime prim__mtime_sec prim__mtime_nsec p
  rdevMajor <- primIO (prim__rdev_major p)
  rdevMinor <- primIO (prim__rdev_minor p)
  devMajor <- primIO (prim__dev_major p)
  devMinor <- primIO (prim__dev_minor p)
  mntId <- primIO (prim__mnt_id p)
  pure (MkStatx mask blksize attributes nlink uid gid mode ino size blocks attributesMask
                atime btime ctime mtime rdevMajor rdevMinor devMajor devMinor mntId)

statxWith : (AnyPtr -> PrimIO Int32) -> IO (Either Errno Statx)
statxWith call = do
  p <- malloc prim__sizeofStatx
  r <- primIO (call p)
  res <- if r == 0 then Right <$> readStatx p else Left <$> errno
  free p
  pure res

||| The status of a path relative to a directory descriptor (the current
||| directory for `Nothing`). `flags` is an `or` of `AT_SYMLINK_NOFOLLOW`,
||| `AT_EMPTY_PATH` and one of the `AT_STATX_*` sync flags; `mask` is the
||| fields wanted (`STATX_BASIC_STATS`, with `STATX_BTIME` for the birth time).
export
statx : Maybe DirDesc -> String -> (flags : Bits32) -> StatxMask -> IO (Either Errno Statx)
statx dir path flags mask =
  let d = maybe prim__AT_FDCWD (\x => x.rawdirfd) dir
  in statxWith (prim__statx d path flags mask)

||| The status of an open file.
export
fstatx : FileDesc -> StatxMask -> IO (Either Errno Statx)
fstatx fd mask = statxWith (prim__statx fd.rawfd "" AT_EMPTY_PATH mask)
