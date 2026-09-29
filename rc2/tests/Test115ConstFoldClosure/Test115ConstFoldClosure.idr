module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Compiler.RC2.ConstFold's closure and CAF folding, and dispatch through a folded dictionary.
-- Each section is a formerly separate test kept verbatim as its own
-- module (its `main` renamed `run`); see rc2/tests/README.md.

import Test115ConstFoldClosure.ConstFoldClosure
import Test115ConstFoldClosure.ConstFoldClosureCallthrough

main : IO ()
main = do
    ConstFoldClosure.run
    ConstFoldClosureCallthrough.run
