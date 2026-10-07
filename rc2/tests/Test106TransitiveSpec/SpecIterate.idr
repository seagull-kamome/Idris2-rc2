module Test106TransitiveSpec.SpecIterate

-- Iterating the specialization passes to a fixpoint
-- (`Compiler.RC2.SpecClosure.applySpecRounds`, see
-- `doc/speculative-closure-specialization.md`, "Iteration"). One round
-- of closure-then-constant-constructor specialization is not enough
-- here:
--
--   round 1: `run` is called with the constant dictionary `ops`, so
--            the constant-constructor half clones it; folding the
--            clone's `case` binds the `step` field to the constant
--            closure `incr`, so the clone now calls
--            `applyAll incr 0 xs` (and, as the clone's own profit, the
--            one `step 0` dispatch folds to a direct call) -- a closure key that did not exist in
--            the program before (the closure half had already run).
--   round 2: the closure half sees that key and clones `applyAll`.
--
-- `applyAll` has two callers (`run` and `plain`, which passes a
-- different closure) and is too big for Inline to fold into either,
-- and so is `run`; `%noinline` is not consulted by rc2's Inline.

import Data.List

record Ops where
  constructor MkOps
  step : Int -> Int
  name : String

incr : Int -> Int
incr x = x + 3

applyAll : (Int -> Int) -> Int -> List Int -> List Int
applyAll f acc [] = [acc, acc * 2, acc - 7]
applyAll f acc (x :: xs) =
  let y = f x
  in if y > acc then y :: applyAll f y xs
     else if y == acc then acc :: applyAll f (acc + 1) xs
     else if y < 0 then negate y :: applyAll f (acc - 1) xs
     else y :: applyAll f acc xs

run : Ops -> List Int -> String
run (MkOps step name) xs =
  let ys = applyAll step 0 xs
      zs = if length ys > 3 then take 3 ys else ys
  in name ++ ":" ++ show (step 0) ++ ":" ++ show (zs ++ [sum ys, product (take 2 zs), cast (length xs)])

plain : Int -> List Int -> List Int
plain k xs = applyAll (\x => x * k + 1) k (xs ++ [k, k + 1, k * 2, k - 3])

ops : Ops
ops = MkOps incr "incr"

export
runIt : IO ()
runIt = do
  putStrLn (run ops [5, 3, 9, 1, 7, 2, 8])
  putStrLn (run ops [4, 4, 1])
  printLn (plain 2 [1, 2, 3])
