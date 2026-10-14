module Test120CStruct.CgSpacedStructName

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- A struct that C only knows by its tag (`struct tm`, no typedef):
-- the name has a space in it. `%cg rc2 externStruct=struct tm` and
-- `Struct "struct tm" [...]` use that name verbatim, so the generated
-- code reads `((struct tm*)ptr)->tm_year` and no `typedef struct { ... }
-- struct tm;` is emitted (rc2/doc/directives.md, section 5, and
-- doc/c-struct-support.md, "Tips"). As with every extern struct the
-- field list is nominal: names and C-compatible types must match the
-- real struct, the layout comes from the header.

import System.FFI

%cg rc2 externStruct=struct tm

Tm : Type
Tm = Struct "struct tm" [("tm_sec", Int32), ("tm_min", Int32), ("tm_hour", Int32), ("tm_mday", Int32), ("tm_mon", Int32), ("tm_year", Int32)]

%foreign "C:idris2rc2_test84_make_tm,libc,Test84CgExternStruct.h"
prim__makeTm : Int32 -> Int32 -> Int32 -> PrimIO Tm

%foreign "C:free,libc,stdlib.h"
prim__freeTm : Tm -> PrimIO ()

tmYear : Tm -> Int32
tmYear t = getField t "tm_year"

tmMday : Tm -> Int32
tmMday t = getField t "tm_mday"

setMday : HasIO io => Tm -> Int32 -> io ()
setMday t v = liftIO (setField t "tm_mday" v)

export
run : IO ()
run = do
  t <- primIO (prim__makeTm 5 4 3)
  printLn (the Int32 (getField t "tm_sec"), the Int32 (getField t "tm_min"), the Int32 (getField t "tm_hour"))
  printLn (tmYear t, tmMday t)
  setMday t 20
  printLn (tmMday t)
  primIO (prim__freeTm t)
