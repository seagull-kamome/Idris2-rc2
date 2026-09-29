module Test120CStruct.CgExternStruct

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
--
-- Several names at once: `test_size` is a second directive in this
-- module and `test_pair` a third one in the imported
-- Test120CStruct.Pair. The companion header typedefs all three,
-- so any directive that got lost would fail the C compile the same way.

import System.FFI
import Test120CStruct.Pair

%cg rc2 externStruct=test_point
%cg rc2 externStruct=test_size

Point : Type
Point = Struct "test_point" [("x", Int), ("y", Double)]

Size : Type
Size = Struct "test_size" [("w", Int), ("h", Int)]

%foreign "C:idris2rc2_test84_make_size,libc,Test84CgExternStruct.h"
prim__makeSize : Int -> Int -> PrimIO Size

%foreign "C:idris2rc2_test84_free_point,libc,Test84CgExternStruct.h"
prim__freeSize : Size -> PrimIO ()

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

export
run : IO ()
run = do
  p <- primIO (prim__makePoint 3 4.5)
  printLn (getX p)
  printLn (getY p)
  setY p 9.0
  printLn (getY p)
  primIO (prim__freePoint p)
  s <- primIO (prim__makeSize 6 7)
  printLn (the Int (getField s "w") * getField s "h")
  primIO (prim__freeSize s)
  q <- primIO (prim__makePair 1.25 2.5)
  printLn (sumPair q)
  primIO (prim__freePair q)
