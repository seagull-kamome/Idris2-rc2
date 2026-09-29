module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Compiler.RC2.Inline (rc2/doc/inlining.md): small-function splicing, comparison fusion through a call, and dead code left behind.
-- Each section is a formerly separate test kept verbatim as its own
-- module (its `main` renamed `run`); see rc2/tests/README.md.

import Test114Inline.SmallFunctionInline
import Test114Inline.CompareFusionThroughCall
import Test114Inline.DeadCodeInline

main : IO ()
main = do
    SmallFunctionInline.run
    CompareFusionThroughCall.run
    DeadCodeInline.run
