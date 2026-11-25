module Test114Inline.WideCall

import Data.IORef

-- A function of 24 arguments, past the 20 that took one array before
-- (`MaxExtractFunArgs`, rc2/doc/dual-abi.md item 12): called directly, and
-- through closures that receive their arguments one and several at a time
-- (`idris2rc2_dispatchFn`, `idris2rc2_dispatchWithExtra`). check.sh tests
-- the direct call has no array.

%noinline
wide : Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int
    -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int
wide a b c d e f g h i j k l m n o p q r s t u v w x =
  a + 2*b + 3*c + 4*d + 5*e + 6*f + 7*g + 8*h + 9*i + 10*j + 11*k + 12*l
    + 13*m + 14*n + 15*o + 16*p + 17*q + 18*r + 19*s + 20*t + 21*u + 22*v + 23*w + 24*x

export
run : IO ()
run = do
  printLn (wide 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24)
  -- Through an IORef, so no pass sees which function the closure calls.
  one <- newIORef (wide 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1)
  fn1 <- readIORef one
  printLn (fn1 2)
  two <- newIORef (wide 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2)
  fn2 <- readIORef two
  printLn (fn2 3 4)
  many <- newIORef wide
  fn24 <- readIORef many
  printLn (fn24 3 3 3 3 3 3 3 3 3 3 3 3 3 3 3 3 3 3 3 3 3 3 3 3)
