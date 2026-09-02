module System.FFI.C.Ptr

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Raw, unchecked memory access into a `Ptr`/`GCPtr`-typed region
-- (`System.FFI.malloc`'d memory, a C struct field, or any pointer a
-- %foreign call hands back), dispatched via the `PtrCFFI` interface
-- below rather than a per-type namespace, so a call site just says
-- `unsafePtrFetch p i`/`unsafeGCPtrFetch p i` and lets `p`'s own
-- element type pick the instance. The `Int32` offset is an element
-- index, not a byte offset -- exactly like C's own `p[offset]` array
-- indexing against a `p` typed to the element in question (see
-- support/c/ptr_util.h, which is exactly what these expand to). Unlike
-- `Data.Buffer` there is no embedded size and no bounds checking, and
-- values are read/written at the host's native byte order rather than
-- Data.Buffer's portable little-endian encoding, matching how a real C
-- program reading the same memory would see it.
--
-- Every `prim__fetch*`/`prim__store*` below takes its pointer typed to
-- exactly the element type it reads/writes (`Ptr Bits16` for the
-- `Bits16` pair, etc.) -- no cast or generic `Ptr a` needed anywhere
-- in this file, since each one is only ever meant to be called against
-- a pointer already typed to match.
--
-- `unsafeGCPtrFetch`/`unsafeGCPtrStore` take a `GCPtr` directly rather
-- than a plain `Ptr` because there is no safe way to convert a `GCPtr`
-- to a plain `Ptr` and keep using it: a `GCPtr`'s backing memory is
-- freed the moment the `GCPtr` value itself becomes unreachable, so a
-- `Ptr` extracted from one and used after the `GCPtr` is otherwise
-- dropped is a dangling pointer into already-freed memory (confirmed
-- directly -- an earlier version of this module tried exactly that
-- conversion and it reliably corrupted the heap on a second use). The
-- `GCPtr` argument must stay alive for the whole fetch/store call, so
-- these methods take it directly instead.

%foreign "RC2:idris2rc2_ptr_fetch_u8,libidris2rc2base,ptr_util.h"
prim__fetchBits8 : Ptr Bits8 -> Int32 -> PrimIO Bits8
%foreign "RC2:idris2rc2_ptr_store_u8,libidris2rc2base,ptr_util.h"
prim__storeBits8 : Ptr Bits8 -> Int32 -> Bits8 -> PrimIO ()
%foreign "RC2:idris2rc2_ptr_fetch_u8,libidris2rc2base,ptr_util.h"
prim__fetchBits8GC : GCPtr Bits8 -> Int32 -> PrimIO Bits8
%foreign "RC2:idris2rc2_ptr_store_u8,libidris2rc2base,ptr_util.h"
prim__storeBits8GC : GCPtr Bits8 -> Int32 -> Bits8 -> PrimIO ()

%foreign "RC2:idris2rc2_ptr_fetch_u16,libidris2rc2base,ptr_util.h"
prim__fetchBits16 : Ptr Bits16 -> Int32 -> PrimIO Bits16
%foreign "RC2:idris2rc2_ptr_store_u16,libidris2rc2base,ptr_util.h"
prim__storeBits16 : Ptr Bits16 -> Int32 -> Bits16 -> PrimIO ()
%foreign "RC2:idris2rc2_ptr_fetch_u16,libidris2rc2base,ptr_util.h"
prim__fetchBits16GC : GCPtr Bits16 -> Int32 -> PrimIO Bits16
%foreign "RC2:idris2rc2_ptr_store_u16,libidris2rc2base,ptr_util.h"
prim__storeBits16GC : GCPtr Bits16 -> Int32 -> Bits16 -> PrimIO ()

%foreign "RC2:idris2rc2_ptr_fetch_u32,libidris2rc2base,ptr_util.h"
prim__fetchBits32 : Ptr Bits32 -> Int32 -> PrimIO Bits32
%foreign "RC2:idris2rc2_ptr_store_u32,libidris2rc2base,ptr_util.h"
prim__storeBits32 : Ptr Bits32 -> Int32 -> Bits32 -> PrimIO ()
%foreign "RC2:idris2rc2_ptr_fetch_u32,libidris2rc2base,ptr_util.h"
prim__fetchBits32GC : GCPtr Bits32 -> Int32 -> PrimIO Bits32
%foreign "RC2:idris2rc2_ptr_store_u32,libidris2rc2base,ptr_util.h"
prim__storeBits32GC : GCPtr Bits32 -> Int32 -> Bits32 -> PrimIO ()

%foreign "RC2:idris2rc2_ptr_fetch_u64,libidris2rc2base,ptr_util.h"
prim__fetchBits64 : Ptr Bits64 -> Int32 -> PrimIO Bits64
%foreign "RC2:idris2rc2_ptr_store_u64,libidris2rc2base,ptr_util.h"
prim__storeBits64 : Ptr Bits64 -> Int32 -> Bits64 -> PrimIO ()
%foreign "RC2:idris2rc2_ptr_fetch_u64,libidris2rc2base,ptr_util.h"
prim__fetchBits64GC : GCPtr Bits64 -> Int32 -> PrimIO Bits64
%foreign "RC2:idris2rc2_ptr_store_u64,libidris2rc2base,ptr_util.h"
prim__storeBits64GC : GCPtr Bits64 -> Int32 -> Bits64 -> PrimIO ()

%foreign "RC2:idris2rc2_ptr_fetch_i8,libidris2rc2base,ptr_util.h"
prim__fetchInt8 : Ptr Int8 -> Int32 -> PrimIO Int8
%foreign "RC2:idris2rc2_ptr_store_i8,libidris2rc2base,ptr_util.h"
prim__storeInt8 : Ptr Int8 -> Int32 -> Int8 -> PrimIO ()
%foreign "RC2:idris2rc2_ptr_fetch_i8,libidris2rc2base,ptr_util.h"
prim__fetchInt8GC : GCPtr Int8 -> Int32 -> PrimIO Int8
%foreign "RC2:idris2rc2_ptr_store_i8,libidris2rc2base,ptr_util.h"
prim__storeInt8GC : GCPtr Int8 -> Int32 -> Int8 -> PrimIO ()

%foreign "RC2:idris2rc2_ptr_fetch_i16,libidris2rc2base,ptr_util.h"
prim__fetchInt16 : Ptr Int16 -> Int32 -> PrimIO Int16
%foreign "RC2:idris2rc2_ptr_store_i16,libidris2rc2base,ptr_util.h"
prim__storeInt16 : Ptr Int16 -> Int32 -> Int16 -> PrimIO ()
%foreign "RC2:idris2rc2_ptr_fetch_i16,libidris2rc2base,ptr_util.h"
prim__fetchInt16GC : GCPtr Int16 -> Int32 -> PrimIO Int16
%foreign "RC2:idris2rc2_ptr_store_i16,libidris2rc2base,ptr_util.h"
prim__storeInt16GC : GCPtr Int16 -> Int32 -> Int16 -> PrimIO ()

%foreign "RC2:idris2rc2_ptr_fetch_i32,libidris2rc2base,ptr_util.h"
prim__fetchInt32 : Ptr Int32 -> Int32 -> PrimIO Int32
%foreign "RC2:idris2rc2_ptr_store_i32,libidris2rc2base,ptr_util.h"
prim__storeInt32 : Ptr Int32 -> Int32 -> Int32 -> PrimIO ()
%foreign "RC2:idris2rc2_ptr_fetch_i32,libidris2rc2base,ptr_util.h"
prim__fetchInt32GC : GCPtr Int32 -> Int32 -> PrimIO Int32
%foreign "RC2:idris2rc2_ptr_store_i32,libidris2rc2base,ptr_util.h"
prim__storeInt32GC : GCPtr Int32 -> Int32 -> Int32 -> PrimIO ()

%foreign "RC2:idris2rc2_ptr_fetch_i64,libidris2rc2base,ptr_util.h"
prim__fetchInt64 : Ptr Int64 -> Int32 -> PrimIO Int64
%foreign "RC2:idris2rc2_ptr_store_i64,libidris2rc2base,ptr_util.h"
prim__storeInt64 : Ptr Int64 -> Int32 -> Int64 -> PrimIO ()
%foreign "RC2:idris2rc2_ptr_fetch_i64,libidris2rc2base,ptr_util.h"
prim__fetchInt64GC : GCPtr Int64 -> Int32 -> PrimIO Int64
%foreign "RC2:idris2rc2_ptr_store_i64,libidris2rc2base,ptr_util.h"
prim__storeInt64GC : GCPtr Int64 -> Int32 -> Int64 -> PrimIO ()

-- `Int` reuses idris2rc2_ptr_fetch_i64/store_i64's C symbol with Int64
-- above (both compile to `int64_t`, Compiler.RC2.EmitUtil's
-- cTypeOfCFType) -- same trick as Data.Buffer.RC2's
-- prim__getInt8 -> getBufferByte.
%foreign "RC2:idris2rc2_ptr_fetch_i64,libidris2rc2base,ptr_util.h"
prim__fetchInt : Ptr Int -> Int32 -> PrimIO Int
%foreign "RC2:idris2rc2_ptr_store_i64,libidris2rc2base,ptr_util.h"
prim__storeInt : Ptr Int -> Int32 -> Int -> PrimIO ()
%foreign "RC2:idris2rc2_ptr_fetch_i64,libidris2rc2base,ptr_util.h"
prim__fetchIntGC : GCPtr Int -> Int32 -> PrimIO Int
%foreign "RC2:idris2rc2_ptr_store_i64,libidris2rc2base,ptr_util.h"
prim__storeIntGC : GCPtr Int -> Int32 -> Int -> PrimIO ()

%foreign "RC2:idris2rc2_ptr_fetch_f64,libidris2rc2base,ptr_util.h"
prim__fetchDouble : Ptr Double -> Int32 -> PrimIO Double
%foreign "RC2:idris2rc2_ptr_store_f64,libidris2rc2base,ptr_util.h"
prim__storeDouble : Ptr Double -> Int32 -> Double -> PrimIO ()
%foreign "RC2:idris2rc2_ptr_fetch_f64,libidris2rc2base,ptr_util.h"
prim__fetchDoubleGC : GCPtr Double -> Int32 -> PrimIO Double
%foreign "RC2:idris2rc2_ptr_store_f64,libidris2rc2base,ptr_util.h"
prim__storeDoubleGC : GCPtr Double -> Int32 -> Double -> PrimIO ()

%foreign "RC2:idris2rc2_ptr_fetch_ptr,libidris2rc2base,ptr_util.h"
prim__fetchAnyPtr : Ptr AnyPtr -> Int32 -> PrimIO AnyPtr
%foreign "RC2:idris2rc2_ptr_store_ptr,libidris2rc2base,ptr_util.h"
prim__storeAnyPtr : Ptr AnyPtr -> Int32 -> AnyPtr -> PrimIO ()
%foreign "RC2:idris2rc2_ptr_fetch_ptr,libidris2rc2base,ptr_util.h"
prim__fetchAnyPtrGC : GCPtr AnyPtr -> Int32 -> PrimIO AnyPtr
%foreign "RC2:idris2rc2_ptr_store_ptr,libidris2rc2base,ptr_util.h"
prim__storeAnyPtrGC : GCPtr AnyPtr -> Int32 -> AnyPtr -> PrimIO ()


public export
interface PtrCFFI a where
  unsafePtrFetch : Ptr a -> Int32 -> IO a
  unsafePtrStore : Ptr a -> Int32 -> a -> IO ()
  unsafeGCPtrFetch : GCPtr a -> Int32 -> IO a
  unsafeGCPtrStore : GCPtr a -> Int32 -> a -> IO ()


export %inline
PtrCFFI Bits8 where
  unsafePtrFetch p i = primIO $ prim__fetchBits8 p i
  unsafePtrStore p i x = primIO $ prim__storeBits8 p i x
  unsafeGCPtrFetch p i = primIO $ prim__fetchBits8GC p i
  unsafeGCPtrStore p i x = primIO $ prim__storeBits8GC p i x

export %inline
PtrCFFI Bits16 where
  unsafePtrFetch p i = primIO $ prim__fetchBits16 p i
  unsafePtrStore p i x = primIO $ prim__storeBits16 p i x
  unsafeGCPtrFetch p i = primIO $ prim__fetchBits16GC p i
  unsafeGCPtrStore p i x = primIO $ prim__storeBits16GC p i x

export %inline
PtrCFFI Bits32 where
  unsafePtrFetch p i = primIO $ prim__fetchBits32 p i
  unsafePtrStore p i x = primIO $ prim__storeBits32 p i x
  unsafeGCPtrFetch p i = primIO $ prim__fetchBits32GC p i
  unsafeGCPtrStore p i x = primIO $ prim__storeBits32GC p i x

export %inline
PtrCFFI Bits64 where
  unsafePtrFetch p i = primIO $ prim__fetchBits64 p i
  unsafePtrStore p i x = primIO $ prim__storeBits64 p i x
  unsafeGCPtrFetch p i = primIO $ prim__fetchBits64GC p i
  unsafeGCPtrStore p i x = primIO $ prim__storeBits64GC p i x

export %inline
PtrCFFI Int8 where
  unsafePtrFetch p i = primIO $ prim__fetchInt8 p i
  unsafePtrStore p i x = primIO $ prim__storeInt8 p i x
  unsafeGCPtrFetch p i = primIO $ prim__fetchInt8GC p i
  unsafeGCPtrStore p i x = primIO $ prim__storeInt8GC p i x

export %inline
PtrCFFI Int16 where
  unsafePtrFetch p i = primIO $ prim__fetchInt16 p i
  unsafePtrStore p i x = primIO $ prim__storeInt16 p i x
  unsafeGCPtrFetch p i = primIO $ prim__fetchInt16GC p i
  unsafeGCPtrStore p i x = primIO $ prim__storeInt16GC p i x

export %inline
PtrCFFI Int32 where
  unsafePtrFetch p i = primIO $ prim__fetchInt32 p i
  unsafePtrStore p i x = primIO $ prim__storeInt32 p i x
  unsafeGCPtrFetch p i = primIO $ prim__fetchInt32GC p i
  unsafeGCPtrStore p i x = primIO $ prim__storeInt32GC p i x

export %inline
PtrCFFI Int64 where
  unsafePtrFetch p i = primIO $ prim__fetchInt64 p i
  unsafePtrStore p i x = primIO $ prim__storeInt64 p i x
  unsafeGCPtrFetch p i = primIO $ prim__fetchInt64GC p i
  unsafeGCPtrStore p i x = primIO $ prim__storeInt64GC p i x

export %inline
PtrCFFI Int where
  unsafePtrFetch p i = primIO $ prim__fetchInt p i
  unsafePtrStore p i x = primIO $ prim__storeInt p i x
  unsafeGCPtrFetch p i = primIO $ prim__fetchIntGC p i
  unsafeGCPtrStore p i x = primIO $ prim__storeIntGC p i x

export %inline
PtrCFFI Double where
  unsafePtrFetch p i = primIO $ prim__fetchDouble p i
  unsafePtrStore p i x = primIO $ prim__storeDouble p i x
  unsafeGCPtrFetch p i = primIO $ prim__fetchDoubleGC p i
  unsafeGCPtrStore p i x = primIO $ prim__storeDoubleGC p i x

export %inline
PtrCFFI AnyPtr where
  unsafePtrFetch p i = primIO $ prim__fetchAnyPtr p i
  unsafePtrStore p i x = primIO $ prim__storeAnyPtr p i x
  unsafeGCPtrFetch p i = primIO $ prim__fetchAnyPtrGC p i
  unsafeGCPtrStore p i x = primIO $ prim__storeAnyPtrGC p i x
