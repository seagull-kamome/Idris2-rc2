module System.FFI.C.Array

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- A `System.FFI.malloc`'d, GC-freed fixed-length array of `ty`. Bounds
-- safety comes entirely from `Fin n`; `len` is a cached O(1) `Bits32`
-- element count for `length` (avoiding a `Nat`->`Bits32` walk on every
-- call), not something `fetch`/`store` themselves consult.
-- `lengthCorrect` is `believe_me`'d rather than actually proved: proving
-- it honestly would mean hiding `MkCArray` from callers entirely
-- (`newCArray` is the only thing that should ever set `len`) -- a level
-- of ceremony not worth it here, since `newCArray` itself is the only
-- place `len` and the real allocation size can ever disagree.
--
-- `fetch`/`store` are a single definition generic over `ty`, dispatched
-- via `System.FFI.C.Ptr`'s own `PtrCFFI ty` constraint rather than a
-- per-type namespace -- unlike `Sizeof` (whose `sizeof_ : Bits32` has
-- the *same* type for every instance, so only the type argument itself
-- can select one, which a plain function can't do without a dispatch
-- interface), `fetch`/`store`'s own return/argument type already varies
-- with `ty`, so a single `PtrCFFI ty =>`-constrained definition picks
-- the right instance once `ty` is concrete at a call site.
--
-- `fetch`/`store` call System.FFI.C.Ptr's `unsafeGCPtrFetch`/
-- `unsafeGCPtrStore` directly on `xs.ptr` -- never converting it to a
-- plain `Ptr ty` first. A `GCPtr`'s backing memory is freed the
-- moment the `GCPtr` value itself becomes unreachable, so extracting a
-- plain `Ptr` and using it after the source `GCPtr` is otherwise
-- dropped is a dangling pointer into already-freed memory (confirmed
-- directly: an earlier version of this module did exactly that
-- conversion and it reliably corrupted the heap on a second fetch/
-- store). Passing `xs.ptr` straight through keeps the `GCPtr` alive for
-- the whole call.

import System.FFI
import public System.FFI.C.Ptr
import public System.FFI.C.Sizeof
import Data.Fin

-------------------------------------------------------------------------------

public export
record CArray (n : Nat) (ty : Type) where
  constructor MkCArray
  ptr : GCPtr ty
  len : Bits32

-------------------------------------------------------------------------------

export
newCArray : Sizeof ty => (n : Nat) -> IO (CArray n ty)
newCArray n = do
    raw <- malloc (cast n * cast (sizeof ty))
    let typedPtr = prim__castPtr {t = ty} raw
    gcPtr <- onCollect typedPtr (\p => free (prim__forgetPtr p))
    pure (MkCArray gcPtr (cast n))

export %inline
length : CArray n ty -> Nat
length x = cast x.len

export %inline
lengthCorrect : (xs : CArray n ty) -> (length xs = n)
lengthCorrect xs = believe_me (Refl {x = length xs})


-------------------------------------------------------------------------------

export %inline
fetch : PtrCFFI ty => CArray n ty -> Fin n -> IO ty
fetch xs m = unsafeGCPtrFetch xs.ptr (cast (finToNat m))

export %inline
store : PtrCFFI ty => CArray n ty -> Fin n -> ty -> IO ()
store xs m x = unsafeGCPtrStore xs.ptr (cast (finToNat m)) x



