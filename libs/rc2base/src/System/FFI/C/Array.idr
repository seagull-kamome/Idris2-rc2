module System.FFI.C.Array

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- A `System.FFI.malloc`'d, GC-freed fixed-length array of `ty`. Bounds
-- safety comes entirely from `Fin n`; `len` is a cached O(1) `Bits32`
-- element count for `length` (avoiding a `Nat`->`Bits32` walk on every
-- call), not something `fetch`/`store` themselves consult. No
-- `length x = n` proof is carried: nothing below needs one, and
-- proving it honestly would mean hiding `MkCArray` from callers
-- entirely (`newCArray` is the only thing that should ever set `len`) --
-- a level of ceremony not worth it for a field `fetch`/`store` never
-- read.
--
-- `fetch`/`store` are namespaced per element type (mirroring
-- System.FFI.C.Ptr's own layout) rather than a single definition
-- generic over `ty`: their return/argument type actually varies by
-- `ty` (`IO Bits8` vs `IO Bits16` and so on), so once `ty` is concrete
-- at a call site plain overload resolution against
-- System.FFI.C.Ptr's own same-shaped per-type namespaces picks the
-- right one -- no dispatch interface needed, unlike Sizeof (whose
-- `sizeof_ : Bits32` has the *same* type for every instance, so only
-- the type argument itself can select an instance, which overload
-- resolution alone can't do).
--
-- `fetch`/`store` call System.FFI.C.Ptr's `unsafeGCPtrFetch`/
-- `unsafeGCPtrStore` directly on `xs.ptr` -- never converting it to a
-- plain `Ptr Bits8` first. A `GCPtr`'s backing memory is freed the
-- moment the `GCPtr` value itself becomes unreachable, so extracting a
-- plain `Ptr` and using it after the source `GCPtr` is otherwise
-- dropped is a dangling pointer into already-freed memory (confirmed
-- directly: an earlier version of this module did exactly that
-- conversion and it reliably corrupted the heap on a second fetch/
-- store). Passing `xs.ptr` straight through keeps the `GCPtr` alive for
-- the whole call.

import System.FFI
import System.FFI.C.Ptr
import public System.FFI.C.Sizeof
import Data.Fin

public export
record CArray (n : Nat) (ty : Type) where
  constructor MkCArray
  ptr : GCPtr Bits8
  len : Bits32

export
newCArray : Sizeof ty => (n : Nat) -> IO (CArray n ty)
newCArray n = do
    raw <- malloc (cast n * cast (sizeof ty))
    let typedPtr = prim__castPtr {t = Bits8} raw
    gcPtr <- onCollect typedPtr (\p => free (prim__forgetPtr p))
    pure (MkCArray gcPtr (cast n))

export
length : CArray n ty -> Nat
length x = cast x.len

namespace Bits8
  export
  fetch : CArray n Bits8 -> Fin n -> IO Bits8
  fetch xs m = unsafeGCPtrFetch xs.ptr (cast (finToNat m))
  export
  store : CArray n Bits8 -> Fin n -> Bits8 -> IO ()
  store xs m x = unsafeGCPtrStore xs.ptr (cast (finToNat m)) x

namespace Bits16
  export
  fetch : CArray n Bits16 -> Fin n -> IO Bits16
  fetch xs m = unsafeGCPtrFetch xs.ptr (cast (finToNat m))
  export
  store : CArray n Bits16 -> Fin n -> Bits16 -> IO ()
  store xs m x = unsafeGCPtrStore xs.ptr (cast (finToNat m)) x

namespace Bits32
  export
  fetch : CArray n Bits32 -> Fin n -> IO Bits32
  fetch xs m = unsafeGCPtrFetch xs.ptr (cast (finToNat m))
  export
  store : CArray n Bits32 -> Fin n -> Bits32 -> IO ()
  store xs m x = unsafeGCPtrStore xs.ptr (cast (finToNat m)) x

namespace Bits64
  export
  fetch : CArray n Bits64 -> Fin n -> IO Bits64
  fetch xs m = unsafeGCPtrFetch xs.ptr (cast (finToNat m))
  export
  store : CArray n Bits64 -> Fin n -> Bits64 -> IO ()
  store xs m x = unsafeGCPtrStore xs.ptr (cast (finToNat m)) x

namespace Int8
  export
  fetch : CArray n Int8 -> Fin n -> IO Int8
  fetch xs m = unsafeGCPtrFetch xs.ptr (cast (finToNat m))
  export
  store : CArray n Int8 -> Fin n -> Int8 -> IO ()
  store xs m x = unsafeGCPtrStore xs.ptr (cast (finToNat m)) x

namespace Int16
  export
  fetch : CArray n Int16 -> Fin n -> IO Int16
  fetch xs m = unsafeGCPtrFetch xs.ptr (cast (finToNat m))
  export
  store : CArray n Int16 -> Fin n -> Int16 -> IO ()
  store xs m x = unsafeGCPtrStore xs.ptr (cast (finToNat m)) x

namespace Int32
  export
  fetch : CArray n Int32 -> Fin n -> IO Int32
  fetch xs m = unsafeGCPtrFetch xs.ptr (cast (finToNat m))
  export
  store : CArray n Int32 -> Fin n -> Int32 -> IO ()
  store xs m x = unsafeGCPtrStore xs.ptr (cast (finToNat m)) x

namespace Int64
  export
  fetch : CArray n Int64 -> Fin n -> IO Int64
  fetch xs m = unsafeGCPtrFetch xs.ptr (cast (finToNat m))
  export
  store : CArray n Int64 -> Fin n -> Int64 -> IO ()
  store xs m x = unsafeGCPtrStore xs.ptr (cast (finToNat m)) x

namespace Int
  export
  fetch : CArray n Int -> Fin n -> IO Int
  fetch xs m = unsafeGCPtrFetch xs.ptr (cast (finToNat m))
  export
  store : CArray n Int -> Fin n -> Int -> IO ()
  store xs m x = unsafeGCPtrStore xs.ptr (cast (finToNat m)) x

namespace Double
  export
  fetch : CArray n Double -> Fin n -> IO Double
  fetch xs m = unsafeGCPtrFetch xs.ptr (cast (finToNat m))
  export
  store : CArray n Double -> Fin n -> Double -> IO ()
  store xs m x = unsafeGCPtrStore xs.ptr (cast (finToNat m)) x

namespace AnyPtr
  export
  fetch : CArray n AnyPtr -> Fin n -> IO AnyPtr
  fetch xs m = unsafeGCPtrFetch xs.ptr (cast (finToNat m))
  export
  store : CArray n AnyPtr -> Fin n -> AnyPtr -> IO ()
  store xs m x = unsafeGCPtrStore xs.ptr (cast (finToNat m)) x
