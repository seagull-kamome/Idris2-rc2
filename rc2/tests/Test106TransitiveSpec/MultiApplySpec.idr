module Test106TransitiveSpec.MultiApplySpec

-- Closure specialisation of callees that apply their closure
-- parameter more than once (`Compiler.RC2.SpecClosure.paramUses`,
-- `multiApplyMaxSize`; doc/speculative-closure-specialization.md,
-- "Multiple apply chains").

import Data.List
import System

incr : Int -> Int
incr x = x + 3

dbl : Int -> Int
dbl x = x * 2

-- Two applications; each caller below passes a different closure so
-- the callee is not simply inlined.
twice : (Int -> Int) -> Int -> List Int -> List Int
twice f k xs = case xs of
  [] => [k]
  (y :: ys) => f (f y) :: f k :: twice f (k + 1) ys

thrice : (Int -> Int) -> Int -> List Int -> List Int
thrice f k xs = case xs of
  [] => [f k]
  (y :: ys) => let r = thrice f (k + 1) ys in f (f y) :: map f r

-- Same shape as `thrice` but over the size threshold: stays generic.
medium : (Int -> Int) -> Int -> List Int -> List Int
medium f k xs = case xs of
  [] => [f k]
  (y :: ys) => f (f (f y)) :: f k :: f (k * 2) :: f (k * 3 + y) :: medium f (k + 1) ys

-- Self-recursive, two applications per step.
rec2 : (Int -> Int) -> Int -> Int -> Int
rec2 f 0 acc = f acc
rec2 f n acc = let a = f (f acc) in rec2 f (n - 1) (a + n * 3 - (a `mod` 5) + (acc * acc) `div` 7 + (n * n) `mod` 11 - acc `div` 3 + n)

fwd : (Int -> Int) -> List Int -> Int
fwd f xs = case xs of
  [] => f 0
  (y :: ys) => f y + f (f y) + fwd f ys

-- Over the size threshold: stays generic.
big : (Int -> Int) -> Int -> List Int -> List Int
big f k xs = case xs of
  [] => [f k, f (k + 1)]
  (y :: ys) =>
    let a = f (y + 1) * 3 + f y
        b = (a * a + y * 7 - k * 5 + a `mod` 11) * 13 + (k * k - y) `div` 3
        c = (b * b + a * 17 - y * y * 19 + b `mod` 23) * 29 + (a * a - b) `div` 5
        d = (c * c + b * 31 - a * a * 37 + c `mod` 41) * 43 + (b * b - c) `div` 7
        e = (d * d + c * 47 - b * b * 53 + d `mod` 59) * 61 + (c * c - d) `div` 9
    in (a + b + c + d + e) :: big f (k + 1) ys

export
run : IO ()
run = do
  n <- (cast . length) <$> getArgs
  let xs : List Int = [1, 2, 3, 4] ++ replicate (cast n) 9
  printLn (twice incr 10 xs)
  printLn (twice dbl 10 xs)
  printLn (thrice incr 1 xs)
  printLn (thrice dbl 1 xs)
  printLn (medium incr 1 xs)
  printLn (medium dbl 1 xs)
  printLn (twice (\x => x + n) 10 xs)
  printLn (twice (\x => x * n) 10 xs)
  printLn (rec2 incr (5 + n) 1)
  printLn (rec2 dbl (4 + n) 1)
  printLn (fwd incr xs)
  printLn (fwd dbl xs)
  printLn (big incr 1 xs)
  printLn (big dbl 1 xs)
