module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Closures: a unique closure growing in place and the closure-context skip.
-- Each section is a formerly separate test kept verbatim as its own
-- module (its `main` renamed `run`); see rc2/tests/README.md.

import Test172Closures.ClosureInPlaceGrow
import Test172Closures.ClosureCtxSkip

main : IO ()
main = do
    ClosureInPlaceGrow.run
    ClosureCtxSkip.run
