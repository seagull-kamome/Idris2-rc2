module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Direct %foreign calls diffed against real RefC: strings, wide dual-ABI workers, malloc/free, Integer arguments and results, `CExpr:` expressions.
-- Each section is a formerly separate test kept verbatim as its own
-- module (its `main` renamed `run`); see rc2/tests/README.md.

import Test118FFI.FFIStrings
import Test118FFI.WideDualABIWorker
import Test118FFI.FFIMalloc
import Test118FFI.FFIInteger
import Test118FFI.FFICExpr

main : IO ()
main = do
    FFIStrings.run
    WideDualABIWorker.run
    FFIMalloc.run
    FFIInteger.run
    FFICExpr.run
