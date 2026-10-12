module System.Posix.FileDesc

import Control.Linear.LIO
import System.Posix.Errno


%default total


-------------------------------------------------------------------------------
--


||| A wrapped POSIX file descriptor.
public export
record FileDesc where
  constructor MkFileDesc
  rawfd : Bits32


||| Convert a raw file descriptor to a `FileDesc`, returning `Nothing` on error.
public export
primFdToFileDesc : Int32 -> IO (Either Errno FileDesc)
primFdToFileDesc fd = if fd < 0
    then pure $ Left !(errno)
    else pure $ Right $ MkFileDesc (cast fd)


%inline %foreign "CExpr:close($1),libc,unistd.h"
prim__close : Bits32 -> PrimIO Int32

||| Close a file descriptor.
public export
close : FileDesc -> IO Int32
close fd = primIO $ prim__close fd.rawfd

-------------------------------------------------------------------------------
--
||| A wrapped POSIX directory descriptor.
public export
record DirDesc where
  constructor MkDirDesc
  rawdirfd : Bits32


