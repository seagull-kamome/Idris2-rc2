module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for `%cg rc2 externStruct=<name>`
-- (Compiler.RC2.RC2's getExternStructs, Compiler.RC2.Emit's header).
-- Unlike Test24CStructSupport (whose own companion header exposes its
-- functions as void* specifically to dodge a duplicate-typedef clash
-- with rc2's own generated `typedef struct { ... } test_point;`),
-- this test's own companion header declares the REAL "test_point"
-- typedef itself -- the same shape a genuine system/library header
-- would already provide (a real-world example: libcurl's own
-- curl/curl.h already typedefs "curl_version_info_data", see the
-- sibling idris2-curl repo's doc/version-info-struct.md). Without the
-- `%cg rc2 externStruct=test_point` directive below, rc2's own
-- unconditional struct-collection pass (Part C,
-- doc/c-struct-support.md) would emit a second, conflicting
-- `typedef struct { ... } test_point;` and fail to compile with
-- "conflicting types for 'test_point'" -- see rc2/doc/directives.md.
--
-- The directive only suppresses that emitted typedef -- `getField`/
-- `setField` still resolve "x"/"y" against the field list given to
-- `Struct` below exactly as normal (Test24CStructSupport's own
-- getX/getY/setX/setY pattern, reused here), since StructDefs itself
-- (Compiler.RC2.Emit.Util) is never filtered, only the typedef
-- emission is.

import System.FFI

%cg rc2 externStruct=test_point

Point : Type
Point = Struct "test_point" [("x", Int), ("y", Double)]

%foreign "C:idris2rc2_test84_make_point,libc,Test84CgExternStruct.h"
prim__makePoint : Int -> Double -> PrimIO Point

%foreign "C:idris2rc2_test84_free_point,libc,Test84CgExternStruct.h"
prim__freePoint : Point -> PrimIO ()

getX : Point -> Int
getX p = getField p "x"

getY : Point -> Double
getY p = getField p "y"

setY : HasIO io => Point -> Double -> io ()
setY p v = liftIO (setField p "y" v)

main : IO ()
main = do
  p <- primIO (prim__makePoint 3 4.5)
  printLn (getX p)
  printLn (getY p)
  setY p 9.0
  printLn (getY p)
  primIO (prim__freePoint p)
