module System.Posix.Stdio

import Decidable.Equality
import System.FFI.C.Null
import System.Posix.FileDesc
import System.Posix.Errno

-------------------------------------------------------------------------------
--

data RawFile : Type where [external]


export File : Type
File = NonNullPtr RawFile


streamToFile : Ptr RawFile -> IO (Either Errno File)
streamToFile stream with (decEq (isNullPtr stream) False)
  _ | Yes _ = pure $ Right $ MkNonnullPtr stream
  _ | No _  = pure $ Left !(errno)

%inline %foreign "CExpr:(fopen($1, $2)),libc,stdio.h"
prim__fopen : String -> String -> PrimIO (Ptr RawFile)
%inline public export fopen : String -> String -> IO (Either Errno File)
fopen pathname mode =
  primIO (prim__fopen pathname mode) >>= streamToFile


%inline %foreign "CExpr:(fdopen($1, $2)),libc,stdio.h"
prim__fdopen : Bits32 -> String -> PrimIO (Ptr RawFile)
%inline public export fdopen : FileDesc -> String -> IO (Either Errno File)
fdopen fd mode = 
  primIO (prim__fdopen fd.rawfd mode) >>= streamToFile

%inline %foreign "CExpr:(freopen($1, $2, $3)),libc,stdio.h"
prim__freopen : String -> String -> File -> PrimIO (Ptr RawFile)
%inline public export freopen : String -> String -> File -> IO (Either Errno File)
freopen pathname mode stream =
  primIO (prim__freopen pathname mode stream) >>= streamToFile




