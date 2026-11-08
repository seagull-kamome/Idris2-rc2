module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Fixed-width and immediate integers: native inference per width, immediates at their 63-bit boundaries, shifts by the full width, Integer around the immediate range, and Integer/String comparisons fused into `cmp` branches, and nested comparisons of the same operands merged, small-integer promotion and signed overflow wrap.
-- Each section is a formerly separate test kept verbatim as its own
-- module (its `main` renamed `run`); see rc2/tests/README.md.

import Test112Numeric.NativeInts
import Test112Numeric.ImmediateInts
import Test112Numeric.ShiftWidth
import Test112Numeric.ImmediateInteger
import Test112Numeric.BoxedCompare
import Test112Numeric.CmpMerge
import Test112Numeric.SmallIntPromotion
import Test112Numeric.SignedOverflowWrap

main : IO ()
main = do
    NativeInts.run
    ImmediateInts.run
    ShiftWidth.run
    ImmediateInteger.run
    BoxedCompare.run
    CmpMerge.run
    SmallIntPromotion.run
    SignedOverflowWrap.run
