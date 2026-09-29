module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Recursion a million deep that must not overflow the C stack: TRMC (phases 1-3), difference lists, and teardown of long structures.
-- Each section is a formerly separate test kept verbatim as its own
-- module (its `main` renamed `run`); see rc2/tests/README.md.

import Test113DeepRecursion.Trmc
import Test113DeepRecursion.TeardownDeep
import Test113DeepRecursion.ClosureCtx
import Test113DeepRecursion.TrmcHoles
import Test113DeepRecursion.TrmcMutual

main : IO ()
main = do
    Trmc.run
    TeardownDeep.run
    ClosureCtx.run
    TrmcHoles.run
    TrmcMutual.run
