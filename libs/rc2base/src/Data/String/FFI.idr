module Data.String.FFI

import System.FFI

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

||| A non-NULL raw pointer's worth of bytes, as a fresh Idris String --
||| a bare copy, no ownership transfer: the original pointer is left
||| entirely untouched (not freed, not GC-registered), so a caller
||| owning a heap allocation still has to release it separately. Reuses
||| Prelude's own `prim__getString`/`prim__castPtr` (the same
||| `idris2_getString` runtime support-library primitive every backend
||| already provides) rather than declaring a new `%foreign` target.
export
ptrToString : AnyPtr -> Maybe String
ptrToString ptr =
  if prim__nullAnyPtr ptr /= 0
     then Nothing
     else Just (prim__getString (prim__castPtr ptr))


export
ptrToStringFree : AnyPtr -> IO (Maybe String)
ptrToStringFree ptr =
   if prim__nullAnyPtr ptr /= 0
      then pure Nothing
      else do
        let str = prim__getString (prim__castPtr ptr)
        free ptr
        pure $ Just str

