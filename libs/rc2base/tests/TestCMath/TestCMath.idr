module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for System.FFI.C.Math: checks each binding against the
-- value it must produce (exactly where the result is exactly
-- representable, with a tolerance for the logarithmic case), and the
-- classification wrappers against `nan`/`inf`/normal/subnormal values.

import Data.Double
import Data.Double.RC2
import System.FFI.C.Math

approx : Double -> Double -> Bool
approx a b = Math.fabs (a - b) <= 1.0e-12

main : IO ()
main = do
  putStrLn "--- Testing System.FFI.C.Math ---"

  -- absolute value, remainder and sign
  printLn (Math.fabs (-3.5) == 3.5)
  printLn (Math.fmod 7.0 3.0 == 1.0)
  printLn (Math.remainder 5.0 3.0 == -1.0)
  printLn (Math.fdim 5.0 3.0 == 2.0)
  printLn (Math.fdim 3.0 5.0 == 0.0)
  printLn (Math.fmax 2.0 3.0 == 3.0)
  printLn (Math.fmin 2.0 3.0 == 2.0)
  printLn (Math.copysign 2.0 (-1.0) == -2.0)
  printLn (Math.nextafter 1.0 2.0 > 1.0)
  printLn (Math.nextafter 1.0 0.0 < 1.0)
  printLn (Math.fma 2.0 3.0 4.0 == 10.0)

  -- powers and roots
  printLn (Math.pow 2.0 10.0 == 1024.0)
  printLn (Math.pow 2.0 (-1.0) == 0.5)
  printLn (Math.sqrt 16.0 == 4.0)
  printLn (approx (Math.cbrt 27.0) 3.0)
  printLn (Math.hypot 3.0 4.0 == 5.0)

  -- exponential and logarithmic
  printLn (Math.exp 0.0 == 1.0)
  printLn (Math.exp2 10.0 == 1024.0)
  printLn (Math.expm1 0.0 == 0.0)
  printLn (Math.log 1.0 == 0.0)
  printLn (Math.log2 1024.0 == 10.0)
  printLn (approx (Math.log10 1000.0) 3.0)
  printLn (Math.log1p 0.0 == 0.0)

  -- special functions
  printLn (approx (Math.erf 0.0) 0.0)
  printLn (approx (Math.erfc 0.0) 1.0)
  printLn (approx (Math.tgamma 5.0) 24.0)
  printLn (approx (Math.lgamma 1.0) 0.0)

  -- trigonometric
  printLn (Math.sin 0.0 == 0.0)
  printLn (Math.cos 0.0 == 1.0)
  printLn (Math.tan 0.0 == 0.0)
  printLn (Math.asin 0.0 == 0.0)
  printLn (Math.acos 1.0 == 0.0)
  printLn (Math.atan 0.0 == 0.0)
  printLn (Math.atan2 0.0 1.0 == 0.0)
  printLn (Math.atan2 1.0 0.0 > 1.57)

  -- hyperbolic
  printLn (Math.sinh 0.0 == 0.0)
  printLn (Math.cosh 0.0 == 1.0)
  printLn (Math.tanh 0.0 == 0.0)
  printLn (Math.asinh 0.0 == 0.0)
  printLn (Math.acosh 1.0 == 0.0)
  printLn (Math.atanh 0.0 == 0.0)

  -- rounding
  printLn (Math.ceil 2.2 == 3.0)
  printLn (Math.floor 2.8 == 2.0)
  printLn (Math.trunc 2.9 == 2.0)
  printLn (Math.trunc (-2.9) == -2.0)
  printLn (Math.round 2.5 == 3.0)
  printLn (Math.round (-2.5) == -3.0)
  printLn (Math.nearbyint 2.3 == 2.0)
  printLn (Math.rint 2.7 == 3.0)
  printLn (Math.lround 2.5 == 3)
  printLn (Math.llround (-2.5) == -3)

  -- decomposition
  printLn (Math.ldexp 1.5 2 == 6.0)
  printLn (Math.scalbn 1.5 (-1) == 0.75)
  printLn (Math.ilogb 8.0 == 3)
  printLn (Math.logb 8.0 == 3.0)

  -- classification
  printLn (Math.isNaN nan)
  printLn (Math.isInfinite inf)
  printLn (Math.isFinite 1.0)
  printLn (not (Math.isFinite inf))
  printLn (Math.isNormal 1.0)
  printLn (not (Math.isNormal 0.0))
  printLn (not (Math.isNormal (2.2250738585072014e-308 / 4.0)))
  printLn (Math.signBit (-1.0))
  printLn (not (Math.signBit 1.0))
  printLn (Math.signBit (-0.0))

  putStrLn "--- Tests finished ---"
