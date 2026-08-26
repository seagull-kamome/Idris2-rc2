module Prelude.Fix.RC2

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Opt-in fix for rc2's own known `fastPack`/`fastConcat` leak (see
-- KNOWN-BUGS.md): both return a raw `malloc`'d `char *` that rc2's
-- generic FFI-return codegen copies into a fresh `IDRIS2RC2_String`
-- and never frees -- correct for a real external library's `char *`
-- return (which the caller must not free), wrong for these two
-- specifically, which are buffers this project itself owns. Fixed
-- here by having `rc2/support/rc2/idris2rc2_strings.c`'s own
-- `fastPackFixed`/`fastConcatFixed` build and return an
-- already-fully-formed `IDRIS2RC2_Value*` directly, and using `Raw`
-- below (an intentionally-undefined data type) as the `%foreign`
-- return-type placeholder that gets that value passed straight
-- through unmodified. `%transform` substitutes these in for
-- `Prelude.Types.fastPack`/`fastConcat` (and therefore `pack`/
-- `concat`, per upstream's own existing `%transform`s onto those)
-- only for a program that actually imports this module.

||| An intentionally-undefined data type -- rc2's own generic FFI
||| return-value codegen treats any `%foreign` return type it doesn't
||| specifically recognize (`CFUser`) as an opaque `IDRIS2RC2_Value*`
||| pass-through: no copy, no wrap, no free (see `EmitUtil.idr`'s
||| `cTypeOfCFType`/`extractValue`/`packCFType` `CFUser` cases). Used
||| here only as a `%foreign` return-type placeholder for a C function
||| that already builds and returns a real, fully-formed Boxed
||| `IDRIS2RC2_String*` itself -- never actually constructed as an
||| Idris value.
data Raw : Type

%foreign "C:fastPackFixed"
prim__fastPackFixed : List Char -> Raw

%foreign "C:fastConcatFixed"
prim__fastConcatFixed : List String -> Raw

||| Leak-free replacement for `Prelude.Types.fastPack`, automatically
||| substituted in for it via the `%transform` below once this module
||| is imported.
export
fastPackFixed : List Char -> String
fastPackFixed cs = believe_me (prim__fastPackFixed cs)

||| Leak-free replacement for `Prelude.Types.fastConcat`, automatically
||| substituted in for it via the `%transform` below once this module
||| is imported.
export
fastConcatFixed : List String -> String
fastConcatFixed cs = believe_me (prim__fastConcatFixed cs)

%transform "fastPackFixed" Prelude.Types.fastPack = fastPackFixed
%transform "fastConcatFixed" Prelude.Types.fastConcat = fastConcatFixed
