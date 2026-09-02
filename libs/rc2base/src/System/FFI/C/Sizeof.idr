module System.FFI.C.Sizeof

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- The C `sizeof` of an Idris type that corresponds to a native C
-- scalar -- for computing byte offsets/strides when combined with
-- System.FFI.C.Ptr's element-index-based fetch/store (e.g. an element
-- stride in bytes when laying out a raw buffer by hand).

public export
interface Sizeof ty where
  sizeof_ : Bits32

public export %inline
sizeof : (0 ty : Type) -> Sizeof ty => Bits32
sizeof ty = sizeof_ {ty}

public export %inline
Sizeof Bits8 where sizeof_ = 1

public export %inline
Sizeof Bits16 where sizeof_ = 2

public export %inline
Sizeof Bits32 where sizeof_ = 4

public export %inline
Sizeof Bits64 where sizeof_ = 8

public export %inline
Sizeof Int8 where sizeof_ = 1

public export %inline
Sizeof Int16 where sizeof_ = 2

public export %inline
Sizeof Int32 where sizeof_ = 4

public export %inline
Sizeof Int64 where sizeof_ = 8

public export %inline
Sizeof Int where sizeof_ = 8

public export %inline
Sizeof Double where sizeof_ = 8

-- rc2 targets 64-bit hosts only (x86-64/aarch64) -- see also
-- System.FFI.C.Ptr's own AnyPtr fetch/store, which makes the same
-- assumption.
public export %inline
Sizeof AnyPtr where sizeof_ = 8
