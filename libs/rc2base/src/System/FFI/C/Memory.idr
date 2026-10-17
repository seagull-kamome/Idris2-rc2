module System.FFI.C.Memory

import Decidable.Equality
import System.FFI.C.Null
import System.Posix.Errno


-------------------------------------------------------------------------------
--

public export
fromAnyPtr : AnyPtr -> IO (Either Errno NonNullAnyPtr)
fromAnyPtr ptr with (decEq (isNullAnyPtr ptr) False)
  _ | Yes _ =  pure $ Right $ MkNonNullAnyPtr ptr
  _ | No _  = pure $ Left !(errno)



public export Cast AnyPtr (Ptr a) where cast ptr = believe_me ptr
public export Cast (Ptr a) AnyPtr where cast ptr = believe_me ptr

public export
Cast NonNullAnyPtr (NonNullPtr a) where
  cast ptr = MkNonNullPtr (cast ptr.ptr) {prf=believe_me ptr.prf}
public export
Cast (NonNullPtr a) NonNullAnyPtr where
  cast ptr = MkNonNullAnyPtr (cast ptr.ptr) {prf=believe_me ptr.prf}


-------------------------------------------------------------------------------
--

%inline %foreign "CExpr:malloc($1),libc,stdlib.h"
prim__malloc : Int -> PrimIO AnyPtr

%inline public export malloc : HasIO io => (size : Int) -> io (Either Errno NonNullAnyPtr)
malloc size = liftIO $ (primIO (prim__malloc size) >>= fromAnyPtr)


%inline %foreign "CExpr:calloc($1, $2),libc,stdlib.h"
prim__calloc : Int -> Int -> PrimIO AnyPtr

%inline public export
calloc : HasIO io => (memb : Int) -> (count : Int) -> io (Either Errno NonNullAnyPtr)
calloc memb count = liftIO $ (primIO (prim__calloc memb count) >>= fromAnyPtr)



%inline %foreign "CExpr:free($1),libc,stdlib.h"
prim__free : AnyPtr -> PrimIO ()

public export free : HasIO io => (ptr : AnyPtr) -> io ()
free ptr = liftIO $ primIO $ prim__free ptr

-------------------------------------------------------------------------------
--

