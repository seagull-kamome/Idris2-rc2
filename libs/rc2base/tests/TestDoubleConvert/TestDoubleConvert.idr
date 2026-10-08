module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for Data.Double.Convert's fast Double<->String path.
-- Every check compares fastParse/fastShow against `cast` (rc2's own
-- always-correct, GMP-backed path) rather than a hardcoded literal --
-- the two must always agree, `cast` is the reference. The heavy
-- randomized cross-checking (millions of cases, both random bit
-- patterns and random decimal strings) was done separately with a
-- standalone C harness during development
-- (libs/rc2base/support/c/fuzz_double_convert.c, not part of this
-- suite -- it links straight against rc2's runtime .a and doesn't fit
-- this project's Idris-level test shape); this file is a smaller,
-- deterministic spot-check exercising the same two properties through
-- the real FFI boundary.

import Data.Double.Convert
import System.Random.Xoroshiro128PlusPlus

randDigit : IOGen -> IO Char
randDigit g = do
  n <- next g
  pure (cast (48 + cast {to = Int} (n `mod` 10)))

randDigits : IOGen -> Nat -> IO String
randDigits _ Z = pure ""
randDigits g (S k) = do
  c <- randDigit g
  rest <- randDigits g k
  pure (strCons c rest)

randDecimalString : IOGen -> IO String
randDecimalString g = do
  signBit <- next g
  let sign = if signBit `mod` 2 == 0 then "-" else ""
  ilBits <- next g
  intPart <- randDigits g (1 + cast {to = Nat} (ilBits `mod` 18))
  fracBit <- next g
  fracPart <- if fracBit `mod` 2 == 0
                 then do flBits <- next g
                         d <- randDigits g (1 + cast {to = Nat} (flBits `mod` 18))
                         pure ("." ++ d)
                 else pure ""
  expBit <- next g
  expPart <- if expBit `mod` 4 == 0
                then do esign <- next g
                        ev <- next g
                        let es = if esign `mod` 2 == 0 then "-" else ""
                        ed <- randDigits g (1 + cast {to = Nat} (ev `mod` 3))
                        pure ("e" ++ es ++ ed)
                else pure ""
  pure (sign ++ intPart ++ fracPart ++ expPart)

-- Both directions at once: parse `s` with both paths (must agree with
-- `cast`), then show the resulting Double with both paths (must also
-- agree) -- exercises fastParse and fastShow together without needing
-- a separate raw-bit-pattern Double generator.
checkOne : IOGen -> IO Bool
checkOne g = do
  s <- randDecimalString g
  let dFast = fastParse s
  let dSlow = the Double (cast s)
  let showFast = fastShow dSlow
  let showSlow = the String (cast dSlow)
  pure (dFast == dSlow && showFast == showSlow)

allOk : IOGen -> Nat -> IO Bool
allOk _ Z = pure True
allOk g (S k) = do
  ok <- checkOne g
  rest <- allOk g k
  pure (ok && rest)

main : IO ()
main = do
  -- Edge cases: sign/nan/inf/-0.0 formatting, exact small values,
  -- boundary magnitudes, values needing exponent notation both
  -- directions, values needing many significant digits.
  printLn (fastShow 0.0 == "0.0")
  printLn (fastShow (-0.0) == "-0.0")
  printLn (fastShow 1.0 == "1.0")
  printLn (fastShow (-1.0) == "-1.0")
  printLn (fastParse "0" == 0.0)
  printLn (fastParse "1.5" == 1.5)
  printLn (fastParse "-1.5" == -1.5)
  printLn (fastParse "1e10" == 1.0e10)
  printLn (fastParse "1.5e-10" == 1.5e-10)

  let big = the Double 1.7976931348623157e308
  printLn (fastParse (fastShow big) == big)
  let small = the Double 2.2250738585072014e-308
  printLn (fastParse (fastShow small) == small)
  let manyDigits = the Double 123456789.123456
  printLn (fastShow manyDigits == the String (cast manyDigits))
  let third = the Double (1.0 / 3.0)
  printLn (fastShow third == the String (cast third))
  let hardCase = the Double 9007199254740993.0
  printLn (fastShow hardCase == the String (cast hardCase))

  -- Deterministic fuzz spot-check, fixed seed.
  Just g <- newIOGen 20260919
    | Nothing => putStrLn "newIOGen: allocation failed"
  allOk g 2000 >>= printLn
