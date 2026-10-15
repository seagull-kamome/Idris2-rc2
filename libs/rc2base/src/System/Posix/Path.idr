||| Creating and removing file-system entries: `mkdir`, `rmdir`, `unlink`,
||| `link`, `symlink`, `readlink`, `realpath`, `mkfifo`, `mkstemp` and
||| `mkdtemp`.
|||
||| `mkstemp` and `mkdtemp` are POSIX.1-2008; `rename` and `remove` are in
||| `System.Posix.Stdio`.
module System.Posix.Path

import Data.String.FFI
import System.FFI
import System.Posix.Errno
import System.Posix.FileDesc

%default total

%inline %foreign "CExpr:(mkdir($1, $2)),libc,sys/stat.h;sys/types.h"
prim__mkdir : String -> Bits32 -> PrimIO Int32
%inline %foreign "CExpr:(rmdir($1)),libc,unistd.h"
prim__rmdir : String -> PrimIO Int32
%inline %foreign "CExpr:(unlink($1)),libc,unistd.h"
prim__unlink : String -> PrimIO Int32
%inline %foreign "CExpr:(link($1, $2)),libc,unistd.h"
prim__link : String -> String -> PrimIO Int32
%inline %foreign "CExpr:(symlink($1, $2)),libc,unistd.h"
prim__symlink : String -> String -> PrimIO Int32
%inline %foreign "CExpr:(mkfifo($1, $2)),libc,sys/stat.h;sys/types.h"
prim__mkfifo : String -> Bits32 -> PrimIO Int32

||| Create a directory with the given mode (before the process `umask`).
export
mkdir : String -> (mode : Bits32) -> IO (Either Errno ())
mkdir path mode = primIO (prim__mkdir path mode) >>= checkUnit

||| Remove an empty directory.
export
rmdir : String -> IO (Either Errno ())
rmdir path = primIO (prim__rmdir path) >>= checkUnit

||| Remove a name from the file system (not a directory).
export
unlink : String -> IO (Either Errno ())
unlink path = primIO (prim__unlink path) >>= checkUnit

||| Create a hard link: `link existing new`.
export
link : (existing : String) -> (new : String) -> IO (Either Errno ())
link a b = primIO (prim__link a b) >>= checkUnit

||| Create a symbolic link: `symlink target linkpath`.
export
symlink : (target : String) -> (linkpath : String) -> IO (Either Errno ())
symlink a b = primIO (prim__symlink a b) >>= checkUnit

||| Create a FIFO (named pipe) with the given mode.
export
mkfifo : String -> (mode : Bits32) -> IO (Either Errno ())
mkfifo path mode = primIO (prim__mkfifo path mode) >>= checkUnit

-------------------------------------------------------------------------------
-- readlink / realpath

%inline %foreign "CExpr:(readlink($1, (char *)($2), $3)),libc,unistd.h"
prim__readlink : String -> AnyPtr -> Bits64 -> PrimIO Int64
%inline %foreign "CExpr:(((char *)($1))[$2] = 0),libc,unistd.h"
prim__terminate : AnyPtr -> Int64 -> PrimIO Int32
%inline %foreign "CExpr:(realpath($1, NULL)),libc,stdlib.h"
prim__realpath : String -> PrimIO AnyPtr

||| The target of a symbolic link (up to 4095 bytes; a longer one is cut).
export
readlink : String -> IO (Either Errno String)
readlink path = do
  buf <- malloc 4096
  n <- primIO (prim__readlink path buf 4095)
  if n < 0
     then do e <- errno
             free buf
             pure (Left e)
     else do _ <- primIO (prim__terminate buf n)
             case ptrToString buf of
                  Nothing => free buf >> pure (Left (MkErrno 84))
                  Just s => free buf >> pure (Right s)

||| The canonical absolute path: symbolic links, `.` and `..` resolved. The
||| path must exist.
export
realpath : String -> IO (Either Errno String)
realpath path = do
  p <- primIO (prim__realpath path)
  if prim__nullAnyPtr p /= 0
     then Left <$> errno
     else do s <- ptrToStringFree p
             pure (maybe (Left (MkErrno 84)) Right s)

-------------------------------------------------------------------------------
-- mkstemp / mkdtemp

%inline %foreign "CExpr:(strlen($1) + 1),libc,string.h"
prim__strlen1 : String -> PrimIO Int
%inline %foreign "CExpr:(strcpy((char *)($1), $2)),libc,string.h"
prim__strcpy : AnyPtr -> String -> PrimIO AnyPtr

||| A writable C copy of the string (`mkstemp` and `mkdtemp` modify the template).
copyString : String -> IO AnyPtr
copyString s = do
  n <- primIO (prim__strlen1 s)
  buf <- malloc n
  _ <- primIO (prim__strcpy buf s)
  pure buf
%inline %foreign "CExpr:(mkstemp((char *)($1))),libc,stdlib.h"
prim__mkstemp : AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(mkdtemp((char *)($1))),libc,stdlib.h"
prim__mkdtemp : AnyPtr -> PrimIO AnyPtr

||| Create and open a unique temporary file from a template ending in
||| `XXXXXX`; returns the descriptor and the file's name.
export
mkstemp : (template : String) -> IO (Either Errno (FileDesc, String))
mkstemp template = do
  buf <- copyString template
  r <- primIO (prim__mkstemp buf)
  if r < 0
     then do e <- errno
             free buf
             pure (Left e)
     else case ptrToString buf of
               Nothing => free buf >> pure (Left (MkErrno 84))
               Just name => free buf >> pure (maybe (Left EBADF) (\d => Right (d, name)) (mkFileDesc r))

||| Create a unique temporary directory from a template ending in `XXXXXX`;
||| returns the directory's name.
export
mkdtemp : (template : String) -> IO (Either Errno String)
mkdtemp template = do
  buf <- copyString template
  p <- primIO (prim__mkdtemp buf)
  if prim__nullAnyPtr p /= 0
     then do e <- errno
             free buf
             pure (Left e)
     else case ptrToString buf of
               Nothing => free buf >> pure (Left (MkErrno 84))
               Just name => free buf >> pure (Right name)
