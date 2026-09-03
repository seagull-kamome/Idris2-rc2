module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for `%export`'s scalar-only native-C-ABI wrapper
-- synthesis (Compiler.RC2.RC2.validateExport + Compiler.RC2.Emit's
-- own emitExportWrapper -- see rc2/doc/export-support.md for the full
-- design). `add`/`scale` below are called both from ordinary Idris
-- code (`main`, proving the wrapper is purely additive -- the
-- original always-Boxed entry point is untouched) and from plain C
-- (`idris2rc2_test_call_exports_from_c` in the companion .c file,
-- proving the exported symbols are genuinely callable with no
-- Idris/rc2 API involved at all). `unused` is %export'd but never
-- called from anywhere in this program -- proving `%export`'s own
-- root stays reachable through `Compiler.RC2.DeadCode.pruneDeadDefs`
-- even with no ordinary caller.

%export "C:idris2rc2_test_add"
add : Int -> Int -> Int
add x y = x + y

%export "C:idris2rc2_test_scale"
scale : Double -> Double -> Double
scale x y = x * y

%export "C:idris2rc2_test_unused"
unused : Int -> Int
unused x = x * 2

%foreign "C:idris2rc2_test_call_exports_from_c,libc,Test59ExportScalar.h"
prim__callFromC : Int -> PrimIO Int

main : IO ()
main = do
  printLn (add 3 4)
  printLn (scale 2.5 4.0)
  r <- primIO (prim__callFromC 100)
  printLn r
