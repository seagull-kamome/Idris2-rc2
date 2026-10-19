||| Dynamic loading: `dlopen`, `dlsym`, `dlclose`.
|||
||| An address from `dlsym` is an `AnyPtr`. Idris has no way to call a C
||| function pointer on its own: a program that wants to call it declares a
||| `CExpr` that does, such as
||| `%foreign "CExpr:(((double (*)(double))($1))($2))"` for a `double (*)(double)`.
|||
||| Linux-only options (`RTLD_NOLOAD`, `RTLD_NODELETE`, `RTLD_DEEPBIND`, `dladdr`) are in
||| `System.Linux.Dl`.
module System.Posix.Dl

import Data.Maybe
import Data.String.FFI
import System.FFI

%default total

||| An opaque handle of `dlopen`.
public export
data RawDl : Type where [external]

||| A handle to a loaded library (or the main program).
public export
DlHandle : Type
DlHandle = Ptr RawDl

||| Resolve symbols when the library is loaded, or lazily when first used.
%inline %foreign "CExpr:(RTLD_LAZY),libc,dlfcn.h"
export RTLD_LAZY : Bits32
%inline %foreign "CExpr:(RTLD_NOW),libc,dlfcn.h"
export RTLD_NOW : Bits32
||| The library's symbols are available to later libraries.
%inline %foreign "CExpr:(RTLD_GLOBAL),libc,dlfcn.h"
export RTLD_GLOBAL : Bits32
||| The library's symbols are not available to later libraries (the default).
%inline %foreign "CExpr:(RTLD_LOCAL),libc,dlfcn.h"
export RTLD_LOCAL : Bits32

%inline %foreign "CExpr:(dlopen($1, $2)),libc,dlfcn.h"
prim__dlopen : String -> Bits32 -> PrimIO (Ptr RawDl)
%inline %foreign "CExpr:(dlopen(NULL, $1)),libc,dlfcn.h"
prim__dlopenSelf : Bits32 -> PrimIO (Ptr RawDl)
%inline %foreign "CExpr:(dlsym($1, $2)),libc,dlfcn.h"
prim__dlsym : Ptr RawDl -> String -> PrimIO AnyPtr
%inline %foreign "CExpr:(dlclose($1)),libc,dlfcn.h"
prim__dlclose : Ptr RawDl -> PrimIO Int32
%inline %foreign "CExpr:(dlerror()),libc,dlfcn.h"
prim__dlerror : PrimIO AnyPtr

||| The text of the last `dlopen`/`dlsym`/`dlclose` failure.
dlerrorText : IO String
dlerrorText = do
  p <- primIO prim__dlerror
  pure (fromMaybe "unknown dlfcn error" (ptrToString p))

||| Load a library by file name or path (as `dlopen`). `flags` is `RTLD_LAZY`
||| or `RTLD_NOW`, with `RTLD_GLOBAL` or `RTLD_LOCAL`.
export
dlopen : String -> (flags : Bits32) -> IO (Either String DlHandle)
dlopen path flags = do
  h <- primIO (prim__dlopen path flags)
  if prim__nullAnyPtr (prim__forgetPtr h) /= 0 then Left <$> dlerrorText else pure (Right h)

||| A handle to the main program and the libraries loaded with it.
export
dlopenSelf : (flags : Bits32) -> IO (Either String DlHandle)
dlopenSelf flags = do
  h <- primIO (prim__dlopenSelf flags)
  if prim__nullAnyPtr (prim__forgetPtr h) /= 0 then Left <$> dlerrorText else pure (Right h)

||| The address of a symbol. A symbol whose value is NULL gives `Right` of a
||| NULL pointer only when `dlerror` agrees that nothing went wrong.
|||
||| `Right` therefore does not mean the address is usable: a caller that is not
||| sure the symbol cannot be NULL must check it before calling or reading
||| through it (`prim__nullAnyPtr`). A missing symbol is always `Left`.
export
dlsym : DlHandle -> String -> IO (Either String AnyPtr)
dlsym h name = do
  _ <- primIO prim__dlerror
  p <- primIO (prim__dlsym h name)
  if prim__nullAnyPtr p /= 0
     then do e <- primIO prim__dlerror
             case ptrToString e of
                  Nothing => pure (Right p)
                  Just msg => pure (Left msg)
     else pure (Right p)

||| Release a handle; the library is unloaded when its count reaches zero.
export
dlclose : DlHandle -> IO (Either String ())
dlclose h = do
  r <- primIO (prim__dlclose h)
  if r == 0 then pure (Right ()) else Left <$> dlerrorText
