module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for `%export`'s CFStruct support (rc2/doc/export-
-- support.md) -- CFStruct's own marshalling is CFPtr's verbatim (see
-- Compiler.RC2.EmitUtil), so this reuses Test24CStructSupport's own
-- "test_point" struct/companion-C pattern rather than inventing a new
-- one. `getXExport` proves an exported function's own body can do a
-- real getField read through the struct handle it received natively;
-- `scalePoint` (identity) proves the struct pointer itself round-trips
-- unchanged, same as Test60ExportPtr's own CFPtr check.

import System.FFI

Point : Type
Point = Struct "test_point" [("x", Int), ("y", Double)]

%foreign "C:idris2rc2_test61_make_point,libc,Test61ExportStruct.h"
prim__makePoint : Int -> Double -> PrimIO Point

%foreign "C:idris2rc2_test61_free_point,libc,Test61ExportStruct.h"
prim__freePoint : Point -> PrimIO ()

%export "C:idris2rc2_test61_get_x"
getXExport : Point -> Int
getXExport p = getField p "x"

%export "C:idris2rc2_test61_scale_point"
scalePoint : Point -> Point
scalePoint p = p

%foreign "C:idris2rc2_test61_run_check,libc,Test61ExportStruct.h"
prim__runCheck : PrimIO Int

-- `prim__makePoint`/`prim__freePoint` are otherwise unreferenced from
-- any live Idris call graph (the companion C's own run_check builds
-- its point directly, bypassing Idris entirely) -- calling them here
-- keeps Compiler.RC2.DeadCode.pruneDeadDefs from stripping them, which
-- would otherwise strip their own CFStruct "test_point" registration
-- (Compiler.RC2.Emit's StructDefs, populated only from live %foreign
-- defs) out from under getXExport's own getField call.
main : IO ()
main = do
  p <- primIO (prim__makePoint 3 4.5)
  printLn (getXExport p)
  primIO (prim__freePoint p)
  r <- primIO prim__runCheck
  printLn r
