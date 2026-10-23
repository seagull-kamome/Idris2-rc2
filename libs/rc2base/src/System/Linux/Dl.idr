||| Linux extensions of `System.Posix.Dl`: more `dlopen` flags and `dladdr`.
|||
||| `dladdr` is a glibc extension that glibc declares only under
||| `_GNU_SOURCE`: build the program with
||| `IDRIS2_CFLAGS=-D_GNU_SOURCE` (see "Build flags" in `System.Posix.File`).
module System.Linux.Dl

import Data.Maybe
import Data.String.FFI
import System.FFI

%default total

||| Do not load the library; succeed only if it is already loaded. A library that is
||| not loaded gives `Left` with a generic message, since `dlerror` has no text then.
%inline %foreign "CExpr:(RTLD_NOLOAD),libc,dlfcn.h"
export RTLD_NOLOAD : Bits32
||| Do not unload the library on `dlclose`.
%inline %foreign "CExpr:(RTLD_NODELETE),libc,dlfcn.h"
export RTLD_NODELETE : Bits32
||| Search the library's own symbols before the global ones.
%inline %foreign "CExpr:(RTLD_DEEPBIND),libc,dlfcn.h"
export RTLD_DEEPBIND : Bits32

||| What `dladdr` found about an address.
public export
record DlInfo where
  constructor MkDlInfo
  ||| The file the address lies in.
  fileName : String
  ||| The nearest symbol below the address, if any.
  symbolName : Maybe String

export
Show DlInfo where
  show i = "DlInfo " ++ show i.fileName ++ " " ++ show i.symbolName

%inline %foreign "CExpr:(sizeof(Dl_info)),libc,dlfcn.h"
prim__sizeofDlInfo : Int
%inline %foreign "CExpr:(dladdr($1, (Dl_info *)($2))),libc,dlfcn.h"
prim__dladdr : AnyPtr -> AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:((void *)((Dl_info *)($1))->dli_fname),libc,dlfcn.h"
prim__dli_fname : AnyPtr -> PrimIO AnyPtr
%inline %foreign "CExpr:((void *)((Dl_info *)($1))->dli_sname),libc,dlfcn.h"
prim__dli_sname : AnyPtr -> PrimIO AnyPtr

||| The library and the symbol an address belongs to; `Nothing` if the address
||| is in no loaded library.
export
dladdr : AnyPtr -> IO (Maybe DlInfo)
dladdr addr = do
  p <- malloc prim__sizeofDlInfo
  r <- primIO (prim__dladdr addr p)
  res <- if r == 0
            then pure Nothing
            else do f <- primIO (prim__dli_fname p)
                    s <- primIO (prim__dli_sname p)
                    fname <- ptrToString f
                    sname <- ptrToString s
                    pure (Just (MkDlInfo (fromMaybe "" fname) sname))
  free p
  pure res
