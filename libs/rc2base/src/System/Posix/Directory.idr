module System.Posix.Directory

import Data.Buffer
import Data.String.FFI
import System.FFI
import System.Posix.FileDesc


-------------------------------------------------------------------------------
-- 

||| A handle for an opened directory stream.
public export data DIR : Type where

||| A pointer to a directory stream.
public export
DIRPtr : Type
DIRPtr = Ptr DIR


%inline %foreign "CExpr:(opendir($1)),libc,sys/types.h;dirent.h"
prim__opendir : String -> PrimIO DIRPtr

||| Open a directory stream for the given path.
public export opendir : String -> IO DIRPtr
opendir filename = primIO $ prim__opendir filename

%inline %foreign "CExpr:(fdopendir($1)),libc,sys/types.h;dirent.h"
prim__fdopendir : Bits32 -> PrimIO DIRPtr

||| Create a directory stream from an open directory file descriptor.
public export fdopendir : FileDesc -> IO DIRPtr
fdopendir fd = primIO $ prim__fdopendir fd.rawfd


%inline %foreign "CExpr:(closedir($1)),libc,sys/types.h;dirent.h"
prim__closedir : DIRPtr -> PrimIO Int32

||| Close a directory stream.
public export closedir : DIRPtr  -> IO Int32
closedir dirp = primIO $ prim__closedir dirp


-------------------------------------------------------------------------------
-- 
||| Opaque `struct dirent`. Only valid until the next `readdir` on the same
||| stream, so it is read through `PrimIO` accessors; `readdir` copies it
||| into a `DirEntry` at once.
export
data DirEnt : Type where [external]


||| Directory entry type: block device.
%inline public export %foreign "CExpr:(DT_BLK),libc,sys/types.h;dirent.h"
DT_BLK : Bits8
||| Directory entry type: character device.
%inline public export %foreign "CExpr:(DT_CHR),libc,sys/types.h;dirent.h"
DT_CHR : Bits8
||| Directory entry type: directory.
%inline public export %foreign "CExpr:(DT_DIR),libc,sys/types.h;dirent.h"
DT_DIR : Bits8
||| Directory entry type: FIFO.
%inline public export %foreign "CExpr:(DT_FIFO),libc,sys/types.h;dirent.h"
DT_FIFO : Bits8
||| Directory entry type: symbolic link.
%inline public export %foreign "CExpr:(DT_LNK),libc,sys/types.h;dirent.h"
DT_LINK : Bits8
||| Directory entry type: regular file.
%inline public export %foreign "CExpr:(DT_REG),libc,sys/types.h;dirent.h"
DT_REG : Bits8
||| Directory entry type: socket.
%inline public export %foreign "CExpr:(DT_SOCK),libc,sys/types.h;dirent.h"
DT_SOCK : Bits8
||| Directory entry type: unknown.
%inline public export %foreign "CExpr:(DT_UNKNOWN),libc,sys/types.h;dirent.h"
DT_UNKNOWN : Bits8


%foreign "CExpr:(readdir($1)),libc,sys/types.h;dirent.h"
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

||| Read the next directory entry from a directory stream; `Nothing` at the
||| end of the stream (or on error, see `errno`).
export readdir : DIRPtr -> IO (Maybe DirEntry)
readdir dirp = do
  p <- primIO $ prim__readdir dirp
  if prim__nullAnyPtr (prim__forgetPtr p) /= 0
    then pure Nothing
    else do
      n <- primIO $ prim__d_name p
      t <- primIO $ prim__d_type p
      i <- primIO $ prim__d_ino p
      pure $ Just (MkDirEntry n t i)

||| All remaining entries of the stream, in stream order (including "." and "..").
covering export readDirEntries : DIRPtr -> IO (List DirEntry)
readDirEntries dirp = go []
  where
    covering go : List DirEntry -> IO (List DirEntry)
    go acc = do
      Just e <- readdir dirp
        | Nothing => pure (reverse acc)
      go (e :: acc)


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
%inline public export telldir : DIRPtr -> IO Int64
telldir dirp = primIO $ prim__telldir dirp



-------------------------------------------------------------------------------
-- 

%inline %foreign "CExpr:(chdir($1)),libc,unistd.h"
prim__chdir : String -> PrimIO Int32

||| Change the process working directory.
public export chdir : String -> IO Int32
chdir path = primIO $ prim__chdir path


%inline %foreign "CExpr:(fchdir($1)),libc,unistd.h"
prim__fchdir : Bits32 -> PrimIO Int32

||| Change the process working directory using a directory descriptor.
public export fchdir : DirDesc -> IO Int32
fchdir fd = primIO $ prim__fchdir fd.rawdirfd


-------------------------------------------------------------------------------
-- 
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
public export chroot : String -> IO Int32
chroot path = primIO $ prim__chroot path



-------------------------------------------------------------------------------
-- 

%inline %foreign "CExpr:(dirfd($1)),libc,sys/types.h;dirent.h"
prim__dirfd : DIRPtr -> PrimIO Int32

||| Convert a directory stream pointer to a directory descriptor.
%inline public export
dirfd : DIRPtr -> IO (Maybe DirDesc)
dirfd dir = do
  dirfd <- primIO $ prim__dirfd dir
  if dirfd < 0
     then pure Nothing
     else pure $ Just $ MkDirDesc $ cast{to=Bits32} dirfd




