module Main

import System

-- A closure that captured constants only is a constant
-- (`RCConstPartial`, `doc/const-closure-fold.md`): `add4 1` applied step by step
-- to constants leaves a lambda that holds them and misses the rest. A list and
-- a record of such closures are built once, and they are applied one argument
-- at a time, all at once, and with the last argument only.

record Ops where
  constructor MkOps
  first : Int -> Int
  second : Int -> Int

%noinline
add4 : Int -> Int -> Int -> Int -> Int
add4 a b c d = a * 1000 + b * 100 + c * 10 + d

%noinline
h1 : Int -> Int
h1 = let f = add4 1 in let g = f 2 in g 3

%noinline
h2 : Int -> Int
h2 = let f = add4 4 in let g = f 5 in g 6

%noinline
h3 : Int -> Int
h3 = let f = add4 7 in let g = f 8 in g 9

%noinline
ops : Ops
ops = MkOps h1 h3

%noinline
table : List (Int -> Int)
table = [h1, h2, h3]

%noinline
applyAll : List (Int -> Int) -> Int -> List Int
applyAll fs x = map (\f => f x) fs

main : IO ()
main = do
  args <- getArgs
  let k = cast {to = Int} (length args)
  printLn (applyAll table k)
  printLn (ops.first k, ops.second (k + 1))
  printLn (applyAll table (k * 7))
