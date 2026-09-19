module Data.Double.Convert

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- An **opt-in** fast path for `Double`<->`String`, next to (never
-- replacing) rc2's own `cast`, which always goes through
-- `rc2/support/rc2/numeric.c`'s correct-but-GMP-per-call
-- `idris2rc2_parse_double`/`idris2rc2_shortest_double` -- see
-- TODO.md's "Performance: `Double <-> String` cast has no fast path"
-- entry, which names exactly this design (a branch-free
-- `uint64_t`/`__uint128_t` route, GMP kept as the slow-path fallback).
-- `fastParse`/`fastShow` are drop-in replacements for
-- `cast {to=Double}`/`cast {to=String}` specifically for `Double`,
-- not a general string-parsing library -- same total semantics
-- (unparseable input -> 0.0), same output shape (`nan`/`inf`/`-inf`/
-- `-0.0`/shortest-round-trip decimal), just faster on the inputs its
-- own table-driven fast paths can resolve with full confidence.
--
-- `libs/rc2base/support/c/double_convert.c` has the real design
-- writeup (Eisel-Lemire-style parsing, DiyFp/Grisu2-style formatting,
-- both wrapped in an unconditional exact-verification/fallback net
-- onto rc2 core's own `idris2rc2_parse_double`/`idris2rc2_shortest_double`,
-- exposed non-static there for exactly this reuse). See
-- `libs/rc2base/README.md`'s own "Data.Double.Convert" section for the
-- user-facing summary.

%foreign "C:idris2rc2_fastParseDouble, libidris2rc2base, double_convert.h"
prim__fastParseDouble : String -> PrimIO Double

||| Same total semantics as `cast {to=Double}` (unparseable input
||| becomes 0.0), same result for every input -- just faster.
export
fastParse : String -> Double
fastParse s = unsafePerformIO (primIO (prim__fastParseDouble s))

||| `idris2rc2_fastShowDouble` already builds a fully-formed, correctly
||| refcounted/tagged `IDRIS2RC2_String` directly (via
||| `idris2rc2_mkEmptyString`) -- declaring the return type as `String`
||| here would make rc2 wrap it a *second* time via `idris2rc2_mkString`
||| (`packCFType CFString`). An unrecognized type constructor like this
||| one maps to `CFUser` instead, whose `packCFType`/`extractValue`
||| (`Compiler.RC2.Emit`) are both the identity -- the Boxed `Value*`
||| flows through untouched. Same trick as `Data.String.RC2`'s `RawStr`
||| and `Data.TextBuffer`'s `RawStringValue`.
data RawStr : Type

%foreign "C:idris2rc2_fastShowDouble, libidris2rc2base, double_convert.h"
prim__fastShowDouble : Double -> PrimIO RawStr

||| Same output as `cast {to=String}` (shortest round-trip decimal,
||| `nan`/`inf`/`-inf`/`-0.0` handled identically) -- just faster.
export
fastShow : Double -> String
fastShow d = believe_me (unsafePerformIO (primIO (prim__fastShowDouble d)))
