module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Merged regression suite for `%export`'s native-C-ABI wrapper
-- synthesis (Compiler.RC2.RC2.validateExport + Compiler.RC2.Emit's
-- emitExportWrapper -- see rc2/doc/export-support.md for the full
-- design). Seven formerly separate tests, one CFType shape per
-- section, every original doc comment kept verbatim. Each exported
-- function is called both from ordinary Idris (`main`, proving the
-- wrapper is purely additive -- the original always-Boxed entry point
-- is untouched) and from plain C (the companion Test59Export.c,
-- proving the exported symbols are genuinely callable with no
-- Idris/rc2 API involved at all). `main` runs all sections in order;
-- the saved .expected is their concatenation.
--
--   1  scalars: Int / Double, plus an %export'd-but-uncalled root
--                                     (was Test59ExportScalar)
--   2  CFPtr round trip               (was Test60ExportPtr)
--   3  CFStruct (by pointer) + getField in the wrapper body
--                                     (was Test61ExportStruct)
--   4  CFGCPtr as an argument         (was Test62ExportGCPtr)
--   5  CFInteger, both directions (GMP mpz_t out-parameter)
--                                     (was Test63ExportInteger)
--   6  CFString return (caller owns / must free the buffer)
--                                     (was Test64ExportString)
--   7  CFString argument (rc2 copies in, never aliases the caller)
--                                     (was Test65ExportStringArg)

import System.FFI

-- ============================================================
-- Section 1: scalars (was Test59ExportScalar)
-- ============================================================
-- `add`/`scale` are exported scalar-only wrappers. `unused` is
-- %export'd but never called from anywhere in this program -- proving
-- `%export`'s own root stays reachable through
-- `Compiler.RC2.DeadCode.pruneDeadDefs` even with no ordinary caller.

%export "C:idris2rc2_test_add"
add : Int -> Int -> Int
add x y = x + y

%export "C:idris2rc2_test_scale"
scale : Double -> Double -> Double
scale x y = x * y

%export "C:idris2rc2_test_unused"
unused : Int -> Int
unused x = x * 2

%foreign "C:idris2rc2_test_call_exports_from_c,libc,Test59Export.h"
prim__callFromC : Int -> PrimIO Int

-- ============================================================
-- Section 2: CFPtr round trip (was Test60ExportPtr)
-- ============================================================
-- `identityPtr` is exported and called directly from plain C
-- (companion) with a raw, non-Idris-owned pointer, proving the
-- wrapper's own packCFType/extractValue CFPtr round trip is genuine
-- native-C-ABI marshalling, not merely a compiling no-op -- the
-- companion C checks both that the exact same address comes back out
-- and that the memory behind it is still readable (i.e. still live,
-- not something the wrapper's own drop-after-return step freed).

%export "C:idris2rc2_test60_identity"
identityPtr : AnyPtr -> AnyPtr
identityPtr p = p

%foreign "C:idris2rc2_test60_run_check,libc,Test59Export.h"
prim__runCheck60 : PrimIO Int

-- ============================================================
-- Section 3: CFStruct by pointer (was Test61ExportStruct)
-- ============================================================
-- CFStruct's own marshalling is CFPtr's verbatim (see
-- Compiler.RC2.EmitUtil), so this reuses Test24CStructSupport's own
-- "test_point" struct/companion-C pattern. `getXExport` proves an
-- exported function's own body can do a real getField read through the
-- struct handle it received natively; `scalePoint` (identity) proves
-- the struct pointer itself round-trips unchanged.
--
-- `prim__makePoint`/`prim__freePoint` are otherwise unreferenced from
-- any live Idris call graph (the companion C's own run_check builds
-- its point directly, bypassing Idris entirely) -- calling them here
-- keeps Compiler.RC2.DeadCode.pruneDeadDefs from stripping them, which
-- would otherwise strip their own CFStruct "test_point" registration
-- (Compiler.RC2.Emit's StructDefs, populated only from live %foreign
-- defs) out from under getXExport's own getField call.

Point : Type
Point = Struct "test_point" [("x", Int), ("y", Double)]

%foreign "C:idris2rc2_test61_make_point,libc,Test59Export.h"
prim__makePoint : Int -> Double -> PrimIO Point

%foreign "C:idris2rc2_test61_free_point,libc,Test59Export.h"
prim__freePoint : Point -> PrimIO ()

%export "C:idris2rc2_test61_get_x"
getXExport : Point -> Int
getXExport p = getField p "x"

%export "C:idris2rc2_test61_scale_point"
scalePoint : Point -> Point
scalePoint p = p

%foreign "C:idris2rc2_test61_run_check,libc,Test59Export.h"
prim__runCheck61 : PrimIO Int

-- ============================================================
-- Section 4: CFGCPtr as an argument (was Test62ExportGCPtr)
-- ============================================================
-- Argument position only -- a GCPtr return is rejected at compile time
-- (Compiler.RC2.RC2.validateExport) and not exercised here. The
-- companion C constructs a plain, Idris-unaware pointer and hands it
-- straight to the exported wrapper, proving `packCFType CFGCPtr`'s own
-- `idris2rc2_mkGCPointer(raw, NULL)` wrapping of a raw incoming
-- pointer works with no special-casing beyond what CFPtr already
-- needed.

%foreign "C:idris2rc2_test62_peek_byte,libc,Test59Export.h"
prim__peekByte : GCAnyPtr -> PrimIO Int

%export "C:idris2rc2_test62_read_byte"
readByteExport : GCAnyPtr -> PrimIO Int
readByteExport p = prim__peekByte p

%foreign "C:idris2rc2_test62_run_check,libc,Test59Export.h"
prim__runCheck62 : PrimIO Int

-- ============================================================
-- Section 5: CFInteger, both directions (was Test63ExportInteger)
-- ============================================================
-- `addInteger` is called ordinarily from Idris (`main`) and from plain
-- C (companion) with `mpz_t` values built directly via GMP, well
-- outside Int's 64-bit range -- proving the argument-side
-- `idris2rc2_mkIntegerFromMpz` copy-in and the return-side `mpz_t
-- out`-parameter convention (mirroring `%foreign`'s own established
-- Integer-return shape, see Test54FFIInteger) are both genuinely
-- GMP-correct, not just Int64-range-correct. Leak/UAF-sensitive by
-- design.

%export "C:idris2rc2_test63_add"
addInteger : Integer -> Integer -> Integer
addInteger x y = x + y

%foreign "C:idris2rc2_test63_run_check,libc,Test59Export.h"
prim__runCheck63 : PrimIO Int

-- ============================================================
-- Section 6: CFString return (was Test64ExportString)
-- ============================================================
-- Pins down the exact bug the naive generic
-- extractValue-then-drop-then-return path would have (extractValue's
-- own CFString case aliases the Boxed value's own malloc'd buffer, so
-- dropping it before returning would hand the C caller a dangling
-- pointer): `greetStr` is called ordinarily from Idris (`main`) and
-- from plain C (companion), which explicitly `free()`s the returned
-- buffer itself, proving the wrapper's own independent-copy contract.
-- Leak/UAF-sensitive by design.

%export "C:idris2rc2_test64_greet"
greetStr : Int -> String
greetStr n = "hello " ++ show n

%foreign "C:idris2rc2_test64_run_check,libc,Test59Export.h"
prim__runCheck64 : PrimIO Int

-- ============================================================
-- Section 7: CFString argument (was Test65ExportStringArg)
-- ============================================================
-- The companion argument-direction to Section 6's return-direction
-- coverage. `packCFType`'s own CFString case (`idris2rc2_mkString`)
-- already copies the incoming `char *` into a freshly Idris-owned
-- buffer, so this is expected to be safe with no wrapper
-- special-casing -- this section exists to actually pin that down:
-- `strLen` is called from plain C (companion) passing a plain string
-- literal (never Idris/rc2-managed memory) that the C side keeps
-- using, unmodified, after the call returns, proving rc2 never aliases
-- or takes ownership of the caller's own buffer.

%export "C:idris2rc2_test65_strlen"
strLen : String -> Int
strLen s = cast (length s)

%foreign "C:idris2rc2_test65_run_check,libc,Test59Export.h"
prim__runCheck65 : PrimIO Int

main : IO ()
main = do
  -- section 1
  printLn (add 3 4)
  printLn (scale 2.5 4.0)
  r59 <- primIO (prim__callFromC 100)
  printLn r59
  -- section 2
  r60 <- primIO prim__runCheck60
  printLn r60
  -- section 3
  p <- primIO (prim__makePoint 3 4.5)
  printLn (getXExport p)
  primIO (prim__freePoint p)
  r61 <- primIO prim__runCheck61
  printLn r61
  -- section 4
  r62 <- primIO prim__runCheck62
  printLn r62
  -- section 5
  printLn (addInteger 40 2)
  r63 <- primIO prim__runCheck63
  printLn r63
  -- section 6
  putStrLn (greetStr 7)
  r64 <- primIO prim__runCheck64
  printLn r64
  -- section 7
  printLn (strLen "hello!")
  r65 <- primIO prim__runCheck65
  printLn r65
