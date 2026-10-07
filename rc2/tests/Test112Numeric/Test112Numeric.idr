module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Fixed-width and immediate integers: native inference per width, immediates at their 63-bit boundaries, shifts by the full width, Integer around the immediate range, and Integer/String comparisons fused into `cmp` branches.
-- Each section is a formerly separate test kept verbatim as its own
-- module (its `main` renamed `run`); see rc2/tests/README.md.

import Test112Numeric.NativeInts
import Test112Numeric.ImmediateInts
import Test112Numeric.ShiftWidth
import Test112Numeric.ImmediateInteger
import Test112Numeric.BoxedCompare

main : IO ()
main = do
    NativeInts.run
    ImmediateInts.run
    ShiftWidth.run
    ImmediateInteger.run
    BoxedCompare.run
