module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Numeric edge cases checked against a saved output: Euclidean mod with negative operands, minBound div -1, non-finite Double to Integer, Double to Int wrap, the Double/Char Cast matrix and locale-independent Double<->String.
-- Each section is a formerly separate test kept verbatim as its own
-- module (its `main` renamed `run`); see rc2/tests/README.md.

import Test168NumericEdge.EuclidModNegative
import Test168NumericEdge.IntMinDivMinusOne
import Test168NumericEdge.DoubleNonFiniteToInteger
import Test168NumericEdge.DoubleToIntWrap
import Test168NumericEdge.CastMatrix
import Test168NumericEdge.DoubleString

main : IO ()
main = do
    EuclidModNegative.run
    IntMinDivMinusOne.run
    DoubleNonFiniteToInteger.run
    DoubleToIntWrap.run
    CastMatrix.run
    DoubleString.run
