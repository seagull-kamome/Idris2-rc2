module Data.String.FFI

import Data.Maybe
import System.FFI

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Prelude's `prim__getString` is pure: a copy that is bound and used later may be
-- made after the memory it reads has been freed or overwritten. Declared here
-- with `PrimIO` (the same `idris2_getString` of the support library), the copy is
-- ordered with the other effects.
%foreign "C:idris2_getString, libidris2_support, idris_support.h"
prim__getStringIO : Ptr String -> PrimIO String

||| A non-NULL raw pointer's worth of bytes, as a fresh Idris String -- a copy made
||| when the action runs, so it comes before a `free` that follows it. No ownership
||| transfer: the original pointer is left entirely untouched (not freed, not
||| GC-registered), so a caller owning a heap allocation still has to release it
||| separately (or use `ptrToStringFree`). `Nothing` for NULL.
export
ptrToString : AnyPtr -> IO (Maybe String)
ptrToString ptr =
  if prim__nullAnyPtr ptr /= 0
     then pure Nothing
     else Just <$> primIO (prim__getStringIO (prim__castPtr ptr))

||| `ptrToString`, then `free` of the pointer. `Nothing` for NULL, which is not freed.
export
ptrToStringFree : AnyPtr -> IO (Maybe String)
ptrToStringFree ptr = do
  str <- ptrToString ptr
  when (isJust str) (free ptr)
  pure str
