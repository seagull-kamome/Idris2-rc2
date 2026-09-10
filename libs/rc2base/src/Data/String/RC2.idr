||| rc2-specific `String` helpers that step outside the codepoint-wise
||| view every other `String` primitive takes.
|||
||| rc2's `String` is UTF-8 bytes on the wire, but `substr`/`strIndex`/
||| `strLength`/... all count *codepoints* (see
||| `rc2/support/rc2/idris2rc2_strings.c`). That's usually what you want
||| -- except when you're handed a span as raw *byte* offsets (the
||| offsets POSIX `regexec` reports, a length-prefixed field, a
||| protocol frame) and need exactly those bytes back out.
||| `unsafeStringByteSlice` is that cut.
module Data.String.RC2

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

||| Opaque marker, never constructed on the Idris side. Typing the
||| `%foreign` below as this (rather than `String` or `AnyPtr`) keeps
||| rc2's FFI marshaller from re-wrapping the value the C shim already
||| built: `idris2rc2_string_byte_slice` returns a fully-formed,
||| correctly tagged `IDRIS2RC2_String*`, and an unrecognised type
||| constructor maps to `CFUser`, whose pack/extract are the identity
||| -- so the `Value*` flows straight through. Same trick as
||| `Data.TextBuffer`'s `RawStringValue`.
data RawStr : Type

%foreign "C:idris2rc2_string_byte_slice,libidris2rc2base,string_rc2.h"
prim__stringByteSlice : String -> Int -> Int -> PrimIO RawStr

||| The `len` bytes of `s` starting at **byte** offset `off`, as a
||| fresh `String`. One copy (`len` bytes, in C); the result is built
||| as a `String` value directly, with no second marshalling copy.
|||
||| Unsafe on two counts:
|||
||| * No bounds proof. `off` and `len` are clamped to `[0, byte length
|||   of s]` in the C shim, so an out-of-range request is memory-safe
|||   -- it just returns a shorter or empty `String`, not a crash.
||| * It cuts on byte boundaries, but `String` is read back
|||   codepoint-wise. Slicing inside a multi-byte UTF-8 sequence leaves
|||   a stray lead/continuation byte at the edge, which then decodes as
|||   U+FFFD. Caller is responsible for cutting on real character
|||   boundaries when that matters (offsets straight from `regexec` on
|||   valid UTF-8 input already are).
export
unsafeStringByteSlice : (s : String) -> (off, len : Int) -> String
unsafeStringByteSlice s off len =
  believe_me (unsafePerformIO (primIO (prim__stringByteSlice s off len)))

%foreign "C:idris2rc2_string_byte_length,libidris2rc2base,string_rc2.h"
prim__stringByteLength : String -> PrimIO Int

||| The on-the-wire byte length of `s` (`strlen`), as opposed to
||| `Data.String.length`'s codepoint count. For pure-ASCII input the
||| two agree.
export
byteLength : String -> Int
byteLength s = unsafePerformIO (primIO (prim__stringByteLength s))
