module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for rc2's locale-independent Double <-> String casts
-- (support/rc2/numeric.c: idris2rc2_cast_Double_to_string /
-- idris2rc2_cast_string_to_Double). These replace the old
-- snprintf("%f") / atof, which followed LC_NUMERIC and printed a fixed
-- six fractional digits.
--
-- `show` now produces the shortest decimal that parses back to the same
-- double; scientific notation for a decimal point outside (-6, 21].
-- The round-trip block re-parses each printed form with `cast` and
-- checks it equals the original -- so it stays meaningful even though
-- the exact digit strings are hand-maintained here.
--
-- In verify.sh's NO_REFC_DIFF_TESTS: real RefC still uses "%f", so
-- there is no shared baseline (this is a deliberate rc2 divergence,
-- like the String/Char codepoint semantics -- see the top-level
-- README's "Deliberate differences from upstream RefC").

import Data.String

showD : Double -> String
showD = show

roundTrips : Double -> Bool
roundTrips x = cast {to = Double} (show x) == x

main : IO ()
main = do
  putStrLn "--- show ---"
  putStrLn (showD 0.0)
  putStrLn (showD (-0.0))
  putStrLn (showD 1.0)
  putStrLn (showD (-1.0))
  putStrLn (showD 1.5)
  putStrLn (showD 0.1)
  putStrLn (showD 0.3)
  putStrLn (showD 3.14159)
  putStrLn (showD 100.0)
  putStrLn (showD 4000000000.0)
  putStrLn (showD 5000050000000.0)
  putStrLn (showD 1.0e21)
  putStrLn (showD 1.0e-6)
  putStrLn (showD 1.0e-7)
  putStrLn (showD 9007199254740992.0)   -- 2^53
  putStrLn (showD 1.7976931348623157e308)
  putStrLn (showD (0.0 / 0.0))
  putStrLn (showD (1.0 / 0.0))
  putStrLn (showD (-1.0 / 0.0))

  putStrLn "--- parse ---"
  printLn (cast {to = Double} "3.14159" == 3.14159)
  printLn (cast {to = Double} "  +2.5 " == 2.5)
  printLn (cast {to = Double} "1e10" == 1.0e10)
  printLn (cast {to = Double} "1E10" == 1.0e10)
  printLn (the (Maybe Double) (parseDouble "-123.5e2") == Just (-12350.0))

  putStrLn "--- round trip ---"
  printLn (all roundTrips
    [ 0.1, 0.2, 0.3, 3.14159, 2.718281828459045
    , 1.0e21, 1.0e-7, 1.0e300, 1.0e-300
    , 9007199254740993.0, 1234567.891011, -0.000123456 ])

  putStrLn "--- done ---"
