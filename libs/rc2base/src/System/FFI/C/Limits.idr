module System.FFI.C.Limits

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Direct `%foreign` bindings onto C's `<limits.h>` integer limits, named
-- after the macros in camelCase (`INT_MAX` -> `intMax`, ...). Each is a
-- `CExpr:` constant, so the value comes from the target's own headers
-- rather than being hard-coded here.
--
-- `char`'s signedness is implementation-defined, so `charMin`/`charMax`
-- are `Int32` (C also types their macro expressions as `int`), while
-- `schar*`/`uchar*` pin the signed and unsigned 8-bit ranges. `long`
-- and `long long` are both 64-bit on the LP64 targets rc2 supports.
-- POSIX-only additions such as `PATH_MAX`/`SSIZE_MAX` are out of scope.

%inline %foreign "CExpr:(CHAR_BIT),libc,limits.h"
export
charBit : Int32

%inline %foreign "CExpr:(SCHAR_MIN),libc,limits.h"
export
scharMin : Int8

%inline %foreign "CExpr:(SCHAR_MAX),libc,limits.h"
export
scharMax : Int8

%inline %foreign "CExpr:(UCHAR_MAX),libc,limits.h"
export
ucharMax : Bits8

%inline %foreign "CExpr:(CHAR_MIN),libc,limits.h"
export
charMin : Int32

%inline %foreign "CExpr:(CHAR_MAX),libc,limits.h"
export
charMax : Int32

%inline %foreign "CExpr:(MB_LEN_MAX),libc,limits.h"
export
mbLenMax : Int32

%inline %foreign "CExpr:(SHRT_MIN),libc,limits.h"
export
shrtMin : Int16

%inline %foreign "CExpr:(SHRT_MAX),libc,limits.h"
export
shrtMax : Int16

%inline %foreign "CExpr:(USHRT_MAX),libc,limits.h"
export
ushrtMax : Bits16

%inline %foreign "CExpr:(INT_MIN),libc,limits.h"
export
intMin : Int32

%inline %foreign "CExpr:(INT_MAX),libc,limits.h"
export
intMax : Int32

%inline %foreign "CExpr:(UINT_MAX),libc,limits.h"
export
uintMax : Bits32

%inline %foreign "CExpr:(LONG_MIN),libc,limits.h"
export
longMin : Int64

%inline %foreign "CExpr:(LONG_MAX),libc,limits.h"
export
longMax : Int64

%inline %foreign "CExpr:(ULONG_MAX),libc,limits.h"
export
ulongMax : Bits64

%inline %foreign "CExpr:(LLONG_MIN),libc,limits.h"
export
llongMin : Int64

%inline %foreign "CExpr:(LLONG_MAX),libc,limits.h"
export
llongMax : Int64

%inline %foreign "CExpr:(ULLONG_MAX),libc,limits.h"
export
ullongMax : Bits64
