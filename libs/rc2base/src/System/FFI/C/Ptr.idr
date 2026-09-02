module System.FFI.C.Ptr

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Raw, unchecked memory access into a `Ptr Bits8`-typed region
-- (`System.FFI.malloc`'d memory, a C struct field, or any pointer a
-- %foreign call hands back). The `Int32` offset is an element index,
-- not a byte offset -- exactly like C's own `p[offset]` array indexing
-- against a `p` typed to the element in question (see
-- support/c/ptr_util.h, which is exactly what these expand to). Unlike
-- `Data.Buffer` there is no embedded size and no bounds checking, and
-- values are read/written at the host's native byte order rather than
-- Data.Buffer's portable little-endian encoding, matching how a real C
-- program reading the same memory would see it.
--
-- Each type also has a `GCPtr Bits8`-taking `unsafeGCPtrFetch`/
-- `unsafeGCPtrStore` pair, reusing the very same C symbols (a `GCPtr`
-- %foreign argument unwraps to the same raw pointer a plain `Ptr`
-- argument would, Compiler.RC2.EmitUtil's extractValue CFGCPtr case).
-- These exist because there is no safe way to convert `GCPtr Bits8` to
-- a plain `Ptr Bits8` and keep using it: a `GCPtr`'s backing memory is
-- freed the moment the `GCPtr` value itself becomes unreachable, so a
-- `Ptr` extracted from one and used after the `GCPtr` is otherwise
-- dropped is a dangling pointer into already-freed memory (confirmed
-- directly -- an earlier version of this module tried exactly that
-- conversion and it reliably corrupted the heap on a second use). The
-- `GCPtr` argument must stay alive for the whole fetch/store call, so
-- these take it directly instead.

%foreign "RC2:idris2rc2_ptr_fetch_u8,libidris2rc2base,ptr_util.h"
prim__fetchBits8 : Ptr Bits8 -> Int32 -> PrimIO Bits8
%foreign "RC2:idris2rc2_ptr_store_u8,libidris2rc2base,ptr_util.h"
prim__storeBits8 : Ptr Bits8 -> Int32 -> Bits8 -> PrimIO ()
%foreign "RC2:idris2rc2_ptr_fetch_u8,libidris2rc2base,ptr_util.h"
prim__fetchBits8GC : GCPtr Bits8 -> Int32 -> PrimIO Bits8
%foreign "RC2:idris2rc2_ptr_store_u8,libidris2rc2base,ptr_util.h"
prim__storeBits8GC : GCPtr Bits8 -> Int32 -> Bits8 -> PrimIO ()

%foreign "RC2:idris2rc2_ptr_fetch_u16,libidris2rc2base,ptr_util.h"
prim__fetchBits16 : Ptr Bits8 -> Int32 -> PrimIO Bits16
%foreign "RC2:idris2rc2_ptr_store_u16,libidris2rc2base,ptr_util.h"
prim__storeBits16 : Ptr Bits8 -> Int32 -> Bits16 -> PrimIO ()
%foreign "RC2:idris2rc2_ptr_fetch_u16,libidris2rc2base,ptr_util.h"
prim__fetchBits16GC : GCPtr Bits8 -> Int32 -> PrimIO Bits16
%foreign "RC2:idris2rc2_ptr_store_u16,libidris2rc2base,ptr_util.h"
prim__storeBits16GC : GCPtr Bits8 -> Int32 -> Bits16 -> PrimIO ()

%foreign "RC2:idris2rc2_ptr_fetch_u32,libidris2rc2base,ptr_util.h"
prim__fetchBits32 : Ptr Bits8 -> Int32 -> PrimIO Bits32
%foreign "RC2:idris2rc2_ptr_store_u32,libidris2rc2base,ptr_util.h"
prim__storeBits32 : Ptr Bits8 -> Int32 -> Bits32 -> PrimIO ()
%foreign "RC2:idris2rc2_ptr_fetch_u32,libidris2rc2base,ptr_util.h"
prim__fetchBits32GC : GCPtr Bits8 -> Int32 -> PrimIO Bits32
%foreign "RC2:idris2rc2_ptr_store_u32,libidris2rc2base,ptr_util.h"
prim__storeBits32GC : GCPtr Bits8 -> Int32 -> Bits32 -> PrimIO ()

%foreign "RC2:idris2rc2_ptr_fetch_u64,libidris2rc2base,ptr_util.h"
prim__fetchBits64 : Ptr Bits8 -> Int32 -> PrimIO Bits64
%foreign "RC2:idris2rc2_ptr_store_u64,libidris2rc2base,ptr_util.h"
prim__storeBits64 : Ptr Bits8 -> Int32 -> Bits64 -> PrimIO ()
%foreign "RC2:idris2rc2_ptr_fetch_u64,libidris2rc2base,ptr_util.h"
prim__fetchBits64GC : GCPtr Bits8 -> Int32 -> PrimIO Bits64
%foreign "RC2:idris2rc2_ptr_store_u64,libidris2rc2base,ptr_util.h"
prim__storeBits64GC : GCPtr Bits8 -> Int32 -> Bits64 -> PrimIO ()

%foreign "RC2:idris2rc2_ptr_fetch_i8,libidris2rc2base,ptr_util.h"
prim__fetchInt8 : Ptr Bits8 -> Int32 -> PrimIO Int8
%foreign "RC2:idris2rc2_ptr_store_i8,libidris2rc2base,ptr_util.h"
prim__storeInt8 : Ptr Bits8 -> Int32 -> Int8 -> PrimIO ()
%foreign "RC2:idris2rc2_ptr_fetch_i8,libidris2rc2base,ptr_util.h"
prim__fetchInt8GC : GCPtr Bits8 -> Int32 -> PrimIO Int8
%foreign "RC2:idris2rc2_ptr_store_i8,libidris2rc2base,ptr_util.h"
prim__storeInt8GC : GCPtr Bits8 -> Int32 -> Int8 -> PrimIO ()

%foreign "RC2:idris2rc2_ptr_fetch_i16,libidris2rc2base,ptr_util.h"
prim__fetchInt16 : Ptr Bits8 -> Int32 -> PrimIO Int16
%foreign "RC2:idris2rc2_ptr_store_i16,libidris2rc2base,ptr_util.h"
prim__storeInt16 : Ptr Bits8 -> Int32 -> Int16 -> PrimIO ()
%foreign "RC2:idris2rc2_ptr_fetch_i16,libidris2rc2base,ptr_util.h"
prim__fetchInt16GC : GCPtr Bits8 -> Int32 -> PrimIO Int16
%foreign "RC2:idris2rc2_ptr_store_i16,libidris2rc2base,ptr_util.h"
prim__storeInt16GC : GCPtr Bits8 -> Int32 -> Int16 -> PrimIO ()

%foreign "RC2:idris2rc2_ptr_fetch_i32,libidris2rc2base,ptr_util.h"
prim__fetchInt32 : Ptr Bits8 -> Int32 -> PrimIO Int32
%foreign "RC2:idris2rc2_ptr_store_i32,libidris2rc2base,ptr_util.h"
prim__storeInt32 : Ptr Bits8 -> Int32 -> Int32 -> PrimIO ()
%foreign "RC2:idris2rc2_ptr_fetch_i32,libidris2rc2base,ptr_util.h"
prim__fetchInt32GC : GCPtr Bits8 -> Int32 -> PrimIO Int32
%foreign "RC2:idris2rc2_ptr_store_i32,libidris2rc2base,ptr_util.h"
prim__storeInt32GC : GCPtr Bits8 -> Int32 -> Int32 -> PrimIO ()

%foreign "RC2:idris2rc2_ptr_fetch_i64,libidris2rc2base,ptr_util.h"
prim__fetchInt64 : Ptr Bits8 -> Int32 -> PrimIO Int64
%foreign "RC2:idris2rc2_ptr_store_i64,libidris2rc2base,ptr_util.h"
prim__storeInt64 : Ptr Bits8 -> Int32 -> Int64 -> PrimIO ()
%foreign "RC2:idris2rc2_ptr_fetch_i64,libidris2rc2base,ptr_util.h"
prim__fetchInt64GC : GCPtr Bits8 -> Int32 -> PrimIO Int64
%foreign "RC2:idris2rc2_ptr_store_i64,libidris2rc2base,ptr_util.h"
prim__storeInt64GC : GCPtr Bits8 -> Int32 -> Int64 -> PrimIO ()

-- `Int` reuses idris2rc2_ptr_fetch_i64/store_i64's C symbol with Int64
-- above (both compile to `int64_t`, Compiler.RC2.EmitUtil's
-- cTypeOfCFType) -- same trick as Data.Buffer.RC2's
-- prim__getInt8 -> getBufferByte.
%foreign "RC2:idris2rc2_ptr_fetch_i64,libidris2rc2base,ptr_util.h"
prim__fetchInt : Ptr Bits8 -> Int32 -> PrimIO Int
%foreign "RC2:idris2rc2_ptr_store_i64,libidris2rc2base,ptr_util.h"
prim__storeInt : Ptr Bits8 -> Int32 -> Int -> PrimIO ()
%foreign "RC2:idris2rc2_ptr_fetch_i64,libidris2rc2base,ptr_util.h"
prim__fetchIntGC : GCPtr Bits8 -> Int32 -> PrimIO Int
%foreign "RC2:idris2rc2_ptr_store_i64,libidris2rc2base,ptr_util.h"
prim__storeIntGC : GCPtr Bits8 -> Int32 -> Int -> PrimIO ()

%foreign "RC2:idris2rc2_ptr_fetch_f64,libidris2rc2base,ptr_util.h"
prim__fetchDouble : Ptr Bits8 -> Int32 -> PrimIO Double
%foreign "RC2:idris2rc2_ptr_store_f64,libidris2rc2base,ptr_util.h"
prim__storeDouble : Ptr Bits8 -> Int32 -> Double -> PrimIO ()
%foreign "RC2:idris2rc2_ptr_fetch_f64,libidris2rc2base,ptr_util.h"
prim__fetchDoubleGC : GCPtr Bits8 -> Int32 -> PrimIO Double
%foreign "RC2:idris2rc2_ptr_store_f64,libidris2rc2base,ptr_util.h"
prim__storeDoubleGC : GCPtr Bits8 -> Int32 -> Double -> PrimIO ()

%foreign "RC2:idris2rc2_ptr_fetch_ptr,libidris2rc2base,ptr_util.h"
prim__fetchAnyPtr : Ptr Bits8 -> Int32 -> PrimIO AnyPtr
%foreign "RC2:idris2rc2_ptr_store_ptr,libidris2rc2base,ptr_util.h"
prim__storeAnyPtr : Ptr Bits8 -> Int32 -> AnyPtr -> PrimIO ()
%foreign "RC2:idris2rc2_ptr_fetch_ptr,libidris2rc2base,ptr_util.h"
prim__fetchAnyPtrGC : GCPtr Bits8 -> Int32 -> PrimIO AnyPtr
%foreign "RC2:idris2rc2_ptr_store_ptr,libidris2rc2base,ptr_util.h"
prim__storeAnyPtrGC : GCPtr Bits8 -> Int32 -> AnyPtr -> PrimIO ()

namespace Bits8
  export
  unsafePtrFetch : Ptr Bits8 -> Int32 -> IO Bits8
  unsafePtrFetch p i = primIO $ prim__fetchBits8 p i
  export
  unsafePtrStore : Ptr Bits8 -> Int32 -> Bits8 -> IO ()
  unsafePtrStore p i x = primIO $ prim__storeBits8 p i x
  export
  unsafeGCPtrFetch : GCPtr Bits8 -> Int32 -> IO Bits8
  unsafeGCPtrFetch p i = primIO $ prim__fetchBits8GC p i
  export
  unsafeGCPtrStore : GCPtr Bits8 -> Int32 -> Bits8 -> IO ()
  unsafeGCPtrStore p i x = primIO $ prim__storeBits8GC p i x

namespace Bits16
  export
  unsafePtrFetch : Ptr Bits8 -> Int32 -> IO Bits16
  unsafePtrFetch p i = primIO $ prim__fetchBits16 p i
  export
  unsafePtrStore : Ptr Bits8 -> Int32 -> Bits16 -> IO ()
  unsafePtrStore p i x = primIO $ prim__storeBits16 p i x
  export
  unsafeGCPtrFetch : GCPtr Bits8 -> Int32 -> IO Bits16
  unsafeGCPtrFetch p i = primIO $ prim__fetchBits16GC p i
  export
  unsafeGCPtrStore : GCPtr Bits8 -> Int32 -> Bits16 -> IO ()
  unsafeGCPtrStore p i x = primIO $ prim__storeBits16GC p i x

namespace Bits32
  export
  unsafePtrFetch : Ptr Bits8 -> Int32 -> IO Bits32
  unsafePtrFetch p i = primIO $ prim__fetchBits32 p i
  export
  unsafePtrStore : Ptr Bits8 -> Int32 -> Bits32 -> IO ()
  unsafePtrStore p i x = primIO $ prim__storeBits32 p i x
  export
  unsafeGCPtrFetch : GCPtr Bits8 -> Int32 -> IO Bits32
  unsafeGCPtrFetch p i = primIO $ prim__fetchBits32GC p i
  export
  unsafeGCPtrStore : GCPtr Bits8 -> Int32 -> Bits32 -> IO ()
  unsafeGCPtrStore p i x = primIO $ prim__storeBits32GC p i x

namespace Bits64
  export
  unsafePtrFetch : Ptr Bits8 -> Int32 -> IO Bits64
  unsafePtrFetch p i = primIO $ prim__fetchBits64 p i
  export
  unsafePtrStore : Ptr Bits8 -> Int32 -> Bits64 -> IO ()
  unsafePtrStore p i x = primIO $ prim__storeBits64 p i x
  export
  unsafeGCPtrFetch : GCPtr Bits8 -> Int32 -> IO Bits64
  unsafeGCPtrFetch p i = primIO $ prim__fetchBits64GC p i
  export
  unsafeGCPtrStore : GCPtr Bits8 -> Int32 -> Bits64 -> IO ()
  unsafeGCPtrStore p i x = primIO $ prim__storeBits64GC p i x

namespace Int8
  export
  unsafePtrFetch : Ptr Bits8 -> Int32 -> IO Int8
  unsafePtrFetch p i = primIO $ prim__fetchInt8 p i
  export
  unsafePtrStore : Ptr Bits8 -> Int32 -> Int8 -> IO ()
  unsafePtrStore p i x = primIO $ prim__storeInt8 p i x
  export
  unsafeGCPtrFetch : GCPtr Bits8 -> Int32 -> IO Int8
  unsafeGCPtrFetch p i = primIO $ prim__fetchInt8GC p i
  export
  unsafeGCPtrStore : GCPtr Bits8 -> Int32 -> Int8 -> IO ()
  unsafeGCPtrStore p i x = primIO $ prim__storeInt8GC p i x

namespace Int16
  export
  unsafePtrFetch : Ptr Bits8 -> Int32 -> IO Int16
  unsafePtrFetch p i = primIO $ prim__fetchInt16 p i
  export
  unsafePtrStore : Ptr Bits8 -> Int32 -> Int16 -> IO ()
  unsafePtrStore p i x = primIO $ prim__storeInt16 p i x
  export
  unsafeGCPtrFetch : GCPtr Bits8 -> Int32 -> IO Int16
  unsafeGCPtrFetch p i = primIO $ prim__fetchInt16GC p i
  export
  unsafeGCPtrStore : GCPtr Bits8 -> Int32 -> Int16 -> IO ()
  unsafeGCPtrStore p i x = primIO $ prim__storeInt16GC p i x

namespace Int32
  export
  unsafePtrFetch : Ptr Bits8 -> Int32 -> IO Int32
  unsafePtrFetch p i = primIO $ prim__fetchInt32 p i
  export
  unsafePtrStore : Ptr Bits8 -> Int32 -> Int32 -> IO ()
  unsafePtrStore p i x = primIO $ prim__storeInt32 p i x
  export
  unsafeGCPtrFetch : GCPtr Bits8 -> Int32 -> IO Int32
  unsafeGCPtrFetch p i = primIO $ prim__fetchInt32GC p i
  export
  unsafeGCPtrStore : GCPtr Bits8 -> Int32 -> Int32 -> IO ()
  unsafeGCPtrStore p i x = primIO $ prim__storeInt32GC p i x

namespace Int64
  export
  unsafePtrFetch : Ptr Bits8 -> Int32 -> IO Int64
  unsafePtrFetch p i = primIO $ prim__fetchInt64 p i
  export
  unsafePtrStore : Ptr Bits8 -> Int32 -> Int64 -> IO ()
  unsafePtrStore p i x = primIO $ prim__storeInt64 p i x
  export
  unsafeGCPtrFetch : GCPtr Bits8 -> Int32 -> IO Int64
  unsafeGCPtrFetch p i = primIO $ prim__fetchInt64GC p i
  export
  unsafeGCPtrStore : GCPtr Bits8 -> Int32 -> Int64 -> IO ()
  unsafeGCPtrStore p i x = primIO $ prim__storeInt64GC p i x

namespace Int
  export
  unsafePtrFetch : Ptr Bits8 -> Int32 -> IO Int
  unsafePtrFetch p i = primIO $ prim__fetchInt p i
  export
  unsafePtrStore : Ptr Bits8 -> Int32 -> Int -> IO ()
  unsafePtrStore p i x = primIO $ prim__storeInt p i x
  export
  unsafeGCPtrFetch : GCPtr Bits8 -> Int32 -> IO Int
  unsafeGCPtrFetch p i = primIO $ prim__fetchIntGC p i
  export
  unsafeGCPtrStore : GCPtr Bits8 -> Int32 -> Int -> IO ()
  unsafeGCPtrStore p i x = primIO $ prim__storeIntGC p i x

namespace Double
  export
  unsafePtrFetch : Ptr Bits8 -> Int32 -> IO Double
  unsafePtrFetch p i = primIO $ prim__fetchDouble p i
  export
  unsafePtrStore : Ptr Bits8 -> Int32 -> Double -> IO ()
  unsafePtrStore p i x = primIO $ prim__storeDouble p i x
  export
  unsafeGCPtrFetch : GCPtr Bits8 -> Int32 -> IO Double
  unsafeGCPtrFetch p i = primIO $ prim__fetchDoubleGC p i
  export
  unsafeGCPtrStore : GCPtr Bits8 -> Int32 -> Double -> IO ()
  unsafeGCPtrStore p i x = primIO $ prim__storeDoubleGC p i x

namespace AnyPtr
  export
  unsafePtrFetch : Ptr Bits8 -> Int32 -> IO AnyPtr
  unsafePtrFetch p i = primIO $ prim__fetchAnyPtr p i
  export
  unsafePtrStore : Ptr Bits8 -> Int32 -> AnyPtr -> IO ()
  unsafePtrStore p i x = primIO $ prim__storeAnyPtr p i x
  export
  unsafeGCPtrFetch : GCPtr Bits8 -> Int32 -> IO AnyPtr
  unsafeGCPtrFetch p i = primIO $ prim__fetchAnyPtrGC p i
  export
  unsafeGCPtrStore : GCPtr Bits8 -> Int32 -> AnyPtr -> IO ()
  unsafeGCPtrStore p i x = primIO $ prim__storeAnyPtrGC p i x
