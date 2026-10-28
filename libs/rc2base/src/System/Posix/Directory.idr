module System.Posix.Directory

import Data.Buffer
import Data.String.FFI
import System.FFI
import System.Posix.Errno
import System.Posix.FileDesc


-------------------------------------------------------------------------------
-- 

||| A handle for an opened directory stream.
public export data DIR : Type where

||| A pointer to a directory stream.
public export
DIRPtr : Type
DIRPtr = Ptr DIR


-- A stream pointer that is NULL when the call failed.
orErrno : DIRPtr -> IO (Either Errno DIRPtr)
orErrno p =
  if prim__nullAnyPtr (prim__forgetPtr p) /= 0 then Left <$> errno else pure (Right p)

%inline %foreign "CExpr:(opendir($1)),libc,sys/types.h;dirent.h"
prim__opendir : String -> PrimIO DIRPtr

||| Open a directory stream for the given path, or the `errno`.
public export opendir : String -> IO (Either Errno DIRPtr)
opendir filename = primIO (prim__opendir filename) >>= orErrno

%inline %foreign "CExpr:(fdopendir($1)),libc,sys/types.h;dirent.h"
prim__fdopendir : Int32 -> PrimIO DIRPtr

||| Create a directory stream from an open directory file descriptor, or the
||| `errno` (the descriptor is then still the caller's).
public export fdopendir : FileDesc -> IO (Either Errno DIRPtr)
fdopendir fd = primIO (prim__fdopendir fd.rawfd) >>= orErrno


%inline %foreign "CExpr:(closedir($1)),libc,sys/types.h;dirent.h"
prim__closedir : DIRPtr -> PrimIO Int32

||| Close a directory stream.
public export closedir : DIRPtr  -> IO (Either Errno ())
closedir dirp = primIO (prim__closedir dirp) >>= checkUnit


-------------------------------------------------------------------------------
-- 
||| Opaque `struct dirent`. Only valid until the next `readdir` on the same
||| stream, so it is read through `PrimIO` accessors; `readdir` copies it
||| into a `DirEntry` at once.
export
data DirEnt : Type where [external]


||| Directory entry type: block device.
|||
||| Linux and BSD, not in POSIX. Needs a filesystem that fills `d_type`; otherwise `DT_UNKNOWN`.
%inline public export %foreign "CExpr:(DT_BLK),libc,sys/types.h;dirent.h"
DT_BLK : Bits8
||| Directory entry type: character device.
|||
||| Linux and BSD, not in POSIX. Needs a filesystem that fills `d_type`; otherwise `DT_UNKNOWN`.
%inline public export %foreign "CExpr:(DT_CHR),libc,sys/types.h;dirent.h"
DT_CHR : Bits8
||| Directory entry type: directory.
|||
||| Linux and BSD, not in POSIX. Needs a filesystem that fills `d_type`; otherwise `DT_UNKNOWN`.
%inline public export %foreign "CExpr:(DT_DIR),libc,sys/types.h;dirent.h"
DT_DIR : Bits8
||| Directory entry type: FIFO.
|||
||| Linux and BSD, not in POSIX. Needs a filesystem that fills `d_type`; otherwise `DT_UNKNOWN`.
%inline public export %foreign "CExpr:(DT_FIFO),libc,sys/types.h;dirent.h"
DT_FIFO : Bits8
||| Directory entry type: symbolic link.
|||
||| Linux and BSD, not in POSIX. Needs a filesystem that fills `d_type`; otherwise `DT_UNKNOWN`.
%inline public export %foreign "CExpr:(DT_LNK),libc,sys/types.h;dirent.h"
DT_LINK : Bits8
||| Directory entry type: regular file.
|||
||| Linux and BSD, not in POSIX. Needs a filesystem that fills `d_type`; otherwise `DT_UNKNOWN`.
%inline public export %foreign "CExpr:(DT_REG),libc,sys/types.h;dirent.h"
DT_REG : Bits8
||| Directory entry type: socket.
|||
||| Linux and BSD, not in POSIX. Needs a filesystem that fills `d_type`; otherwise `DT_UNKNOWN`.
%inline public export %foreign "CExpr:(DT_SOCK),libc,sys/types.h;dirent.h"
DT_SOCK : Bits8
||| Directory entry type: unknown.
|||
||| Linux and BSD, not in POSIX. Needs a filesystem that fills `d_type`; otherwise `DT_UNKNOWN`.
%inline public export %foreign "CExpr:(DT_UNKNOWN),libc,sys/types.h;dirent.h"
DT_UNKNOWN : Bits8


-- `errno` is cleared first: `readdir` leaves it alone at the end of the stream.
%foreign "CExpr:(({ errno = 0; readdir($1); })),libc,sys/types.h;dirent.h;errno.h"
prim__readdir : DIRPtr -> PrimIO (Ptr DirEnt)

%foreign "CExpr:(((struct dirent *)($1))->d_name),libc,sys/types.h;dirent.h"
prim__d_name : Ptr DirEnt -> PrimIO String

%foreign "CExpr:(((struct dirent *)($1))->d_type),libc,sys/types.h;dirent.h"
prim__d_type : Ptr DirEnt -> PrimIO Bits8

%foreign "CExpr:(((struct dirent *)($1))->d_ino),libc,sys/types.h;dirent.h"
prim__d_ino : Ptr DirEnt -> PrimIO Bits64

||| A directory entry copied out of the stream.
public export
record DirEntry where
  constructor MkDirEntry
  name : String
  type : Bits8
  ino : Bits64

||| Read the next directory entry from a directory stream: `Right Nothing` at
||| the end of the stream, `Left` with the `errno` if reading failed.
export readdir : DIRPtr -> IO (Either Errno (Maybe DirEntry))
readdir dirp = do
  p <- primIO $ prim__readdir dirp
  if prim__nullAnyPtr (prim__forgetPtr p) /= 0
    then do e <- errno
            pure (if e == MkErrno 0 then Right Nothing else Left e)
    else do
      n <- primIO $ prim__d_name p
      t <- primIO $ prim__d_type p
      i <- primIO $ prim__d_ino p
      pure $ Right (Just (MkDirEntry n t i))

||| All remaining entries of the stream, in stream order (including "." and
||| ".."); the `errno` if reading failed.
covering export readDirEntries : DIRPtr -> IO (Either Errno (List DirEntry))
readDirEntries dirp = go []
  where
    covering go : List DirEntry -> IO (Either Errno (List DirEntry))
    go acc = do
      r <- readdir dirp
      case r of
           Left e => pure (Left e)
           Right Nothing => pure (Right (reverse acc))
           Right (Just e) => go (e :: acc)


-------------------------------------------------------------------------------
-- 

%inline %foreign "CExpr:(rewinddir($1)),libc,sys/types.h;dirent.h"
prim__rewinddir : DIRPtr -> PrimIO ()

||| Reset the directory stream to the beginning.
%inline public export rewinddir : DIRPtr -> IO ()
rewinddir dirp = primIO $ prim__rewinddir dirp

%inline %foreign "CExpr:(seekdir($1, $2)),libc,sys/types.h;dirent.h"
prim__seekdir : DIRPtr -> Int64 -> PrimIO ()

||| Move the directory stream to a saved position.
%inline public export seekdir : DIRPtr -> Int64 -> IO ()
seekdir dirp loc = primIO $ prim__seekdir dirp loc


%inline %foreign "CExpr:(telldir($1)),libc,sys/types.h;dirent.h"
prim__telldir : DIRPtr -> PrimIO Int64

||| Return the current position of a directory stream.
%inline public export telldir : DIRPtr -> IO (Either Errno Int64)
telldir dirp = primIO (prim__telldir dirp) >>= checkNonNeg64



-------------------------------------------------------------------------------
-- 

%inline %foreign "CExpr:(chdir($1)),libc,unistd.h"
prim__chdir : String -> PrimIO Int32

||| Change the process working directory.
public export chdir : String -> IO (Either Errno ())
chdir path = primIO (prim__chdir path) >>= checkUnit


%inline %foreign "CExpr:(fchdir($1)),libc,unistd.h"
prim__fchdir : Int32 -> PrimIO Int32

||| Change the process working directory using a directory descriptor.
public export fchdir : DirDesc -> IO (Either Errno ())
fchdir fd = primIO (prim__fchdir fd.rawdirfd) >>= checkUnit


-------------------------------------------------------------------------------
-- 
||| Maximum length of a path name including the terminating NUL.
||| POSIX allows a system to leave it undefined; see `pathconf(3)`.
%inline %foreign "CExpr:(PATH_MAX),libc,limits.h"
export PATH_MAX : Bits32


%inline %foreign "CExpr:(getcwd(NULL, 0)),libc,unistd.h"
prim__getcwd : PrimIO AnyPtr

||| Get the current working directory as a string.
public export getcwd : IO (Maybe String)
getcwd = primIO prim__getcwd >>= ptrToStringFree



-------------------------------------------------------------------------------
-- 

%inline %foreign "CExpr:(chroot($1)),libc,unistd.h"
prim__chroot : String -> PrimIO Int32

||| Change the process root directory.
|||
||| Not in POSIX (removed from the Single UNIX Specification); Linux and BSD. Needs root.
public export chroot : String -> IO (Either Errno ())
chroot path = primIO (prim__chroot path) >>= checkUnit



-------------------------------------------------------------------------------
-- 

%inline %foreign "CExpr:(dirfd($1)),libc,sys/types.h;dirent.h"
prim__dirfd : DIRPtr -> PrimIO Int32

||| The directory descriptor of a directory stream, or the `errno`.
%inline public export
dirfd : DIRPtr -> IO (Either Errno DirDesc)
dirfd dir = primIO (prim__dirfd dir) >>= primFdToDirDesc




