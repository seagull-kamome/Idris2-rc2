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
-- `newCArray` proves its size fits in `maxCArrayBytes`: `System.FFI.malloc`
-- takes a C `int`, so a larger size would be cut and the `Fin` indices would
-- then write past a smaller allocation. The bound also keeps `len` within
-- `Bits32` and the index within `fetch`/`store`'s `Int32`, so `lengthCorrect`
-- does hold. The memory is zeroed, not left as the allocator had it.
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

import Data.List
import Data.So
import System.FFI
import System.FFI.C.Memory as CMem
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

||| The most bytes an array may take: what the `int` size of `System.FFI.malloc`
||| (C's `idris2_malloc(int)`) holds. A larger one would be cut to a smaller
||| size, and the array's `Fin` indices would then write past the allocation.
||| It also keeps the element count within `len : Bits32` and the `Int32` index
||| of `fetch`/`store`.
public export
maxCArrayBytes : Integer
maxCArrayBytes = 2147483647

||| The proof that `n` elements of `ty` fit in `maxCArrayBytes`.
public export
0 FitsCArray : Sizeof ty => (n : Nat) -> Type
FitsCArray {ty} n = So (natToInteger n * cast (sizeof ty) <= maxCArrayBytes)

||| An array of `n` elements, all bytes 0. `n` is proved to fit in
||| `maxCArrayBytes` bytes (found by evaluation for a literal; made with
||| `Data.So.choose` for a count known only at run time).
export
newCArray : Sizeof ty => (n : Nat) -> {auto 0 fits : FitsCArray {ty} n} -> IO (CArray n ty)
newCArray n = do
    let bytes = cast n * cast (sizeof ty)
    raw <- System.FFI.malloc bytes
    when (bytes > 0) $ CMem.memset raw 0 (cast bytes)
    let typedPtr = prim__castPtr {t = ty} raw
    gcPtr <- onCollect typedPtr (\p => System.FFI.free (prim__forgetPtr p))
    pure (MkCArray gcPtr (cast n))

export %inline
length : CArray n ty -> Nat
length x = cast x.len

export %inline
lengthCorrect : (xs : CArray n ty) -> (length xs = n)
lengthCorrect xs = believe_me (Refl {x = length xs})


-------------------------------------------------------------------------------
--

export %inline
fetch : PtrCFFI ty => CArray n ty -> Fin n -> IO ty
fetch xs m = unsafeGCPtrFetch xs.ptr (cast (finToNat m))

export %inline
store : PtrCFFI ty => CArray n ty -> Fin n -> ty -> IO ()
store xs m x = unsafeGCPtrStore xs.ptr (cast (finToNat m)) x


-------------------------------------------------------------------------------
--

||| An array of the mapped elements of the list; `Nothing` when it is too long to
||| fit in `maxCArrayBytes` bytes.
export
fromListBy : PtrCFFI ty => Sizeof ty => (a -> ty) -> (xs : List a) -> IO (Maybe (CArray (length xs) ty))
fromListBy {ty} f xs =
    case choose (natToInteger n * cast (sizeof ty) <= maxCArrayBytes) of
      Left fits => do
        arr <- newCArray n
        for_ (zip (allFins n) xs) $ \(i,x) => store arr i (f x)
        pure (Just arr)
      Right _ => pure Nothing
  where
    n = length xs
