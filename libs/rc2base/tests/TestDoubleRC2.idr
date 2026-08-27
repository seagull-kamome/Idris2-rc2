module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for Data.Double.RC2's four %foreign_impl patches
-- (unitRoundoff/epsilon/nan/inf). Checks the defining properties from
-- each's own upstream doc comment rather than hardcoding a literal
-- value: unitRoundoff is the largest value that leaves 1.0 unchanged
-- when added, epsilon is exactly double that (and the smallest value
-- that does *not* leave 1.0 unchanged), nan compares unequal to itself,
-- inf is larger than any ordinary finite value and its reciprocal is
-- exactly 0.0.

import Data.Double
import Data.Double.RC2

main : IO ()
main = do
  printLn (1.0 + unitRoundoff == 1.0)
  printLn (1.0 + epsilon == 1.0)
  printLn (epsilon == unitRoundoff * 2.0)
  printLn (nan == nan)
  printLn (inf > 1.0e300)
  printLn (1.0 / inf)
