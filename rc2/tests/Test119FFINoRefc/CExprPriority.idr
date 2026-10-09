module Test119FFINoRefc.CExprPriority

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- `CExpr:` has top priority among rc2's FFI tags, whatever the order of
-- the strings (rc2/doc/ffi-cexpr.md): the `C:` shim here would return
-- 222. Real RefC would run the shim, hence not diffed against it.

%foreign "C:idris2rc2_test129_priority,libc,Test129CExprPriority.h"
         "scheme:never-used"
         "CExpr:111"
prim__priorityAfter : Int

%foreign "CExpr:222 + ($1)"
         "RefC:idris2rc2_test129_priority,libc,Test129CExprPriority.h"
prim__priorityRefC : Int -> Int

export
run : IO ()
run = do
  printLn prim__priorityAfter
  printLn (prim__priorityRefC 1)
