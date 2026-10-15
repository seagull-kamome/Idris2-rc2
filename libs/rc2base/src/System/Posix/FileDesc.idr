module System.Posix.FileDesc

import Data.So
import System.Posix.Errno


%default total


-------------------------------------------------------------------------------
--


||| A POSIX file descriptor. The number is never negative; the proof is
||| erased, so a descriptor is built by `mkFileDesc` or `primFdToFileDesc`, or
||| from a literal (`MkFileDesc 99`).
public export
record FileDesc where
  constructor MkFileDesc
  rawfd : Int32
  {auto 0 fdNonNeg : So (rawfd >= 0)}

||| The descriptor of a number, `Nothing` when it is negative.
public export
mkFileDesc : Int32 -> Maybe FileDesc
mkFileDesc fd = case choose (fd >= 0) of
  Left ok => Just (MkFileDesc fd)
  Right _ => Nothing

||| Convert the result of a call that returns a descriptor or -1: the
||| descriptor, or `errno` when the result is negative.
public export
primFdToFileDesc : Int32 -> IO (Either Errno FileDesc)
primFdToFileDesc fd = case mkFileDesc fd of
  Just d => pure (Right d)
  Nothing => Left <$> errno


%inline %foreign "CExpr:close($1),libc,unistd.h"
prim__close : Int32 -> PrimIO Int32

||| Close a file descriptor.
public export
close : FileDesc -> IO Int32
close fd = primIO $ prim__close fd.rawfd

-------------------------------------------------------------------------------
--
||| A POSIX directory descriptor (for the `*at` calls); never negative, like
||| `FileDesc`.
public export
record DirDesc where
  constructor MkDirDesc
  rawdirfd : Int32
  {auto 0 dirfdNonNeg : So (rawdirfd >= 0)}

||| The directory descriptor of a number, `Nothing` when it is negative.
public export
mkDirDesc : Int32 -> Maybe DirDesc
mkDirDesc fd = case choose (fd >= 0) of
  Left ok => Just (MkDirDesc fd)
  Right _ => Nothing

||| A file descriptor of a directory (opened with `O_DIRECTORY`) as a directory
||| descriptor, and the other way round.
public export
asDirDesc : FileDesc -> DirDesc
asDirDesc fd = MkDirDesc fd.rawfd {dirfdNonNeg = fd.fdNonNeg}

public export
asFileDesc : DirDesc -> FileDesc
asFileDesc d = MkFileDesc d.rawdirfd {fdNonNeg = d.dirfdNonNeg}
