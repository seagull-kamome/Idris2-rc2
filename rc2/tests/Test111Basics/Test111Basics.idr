module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Basic language features: arithmetic, recursion (mutual and non-tail), closures and higher-order functions.
-- Each section is a formerly separate test kept verbatim as its own
-- module (its `main` renamed `run`); see rc2/tests/README.md.

import Test111Basics.Basics
import Test111Basics.Recursion
import Test111Basics.Closures

main : IO ()
main = do
    Basics.run
    Recursion.run
    Closures.run
