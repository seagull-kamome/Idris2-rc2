module Main

-- Transitive closure specialisation
-- (rc2/doc/speculative-closure-specialization.md, "Transitive
-- specialisation"): a closure parameter that is only forwarded to
-- other functions still gets specialised along the chain. The helpers
-- are too big for Inline to fold them into their callers, and `twice`
-- has two callers, so it is not inlined as a single-use function either.

import Data.List
import Data.IORef
import Test106TransitiveSpec.SpecIterate
import Test106TransitiveSpec.MultiApplySpec

-- Applies the closure; the other two only forward it.
applyAll : (Int -> Int) -> List Int -> List Int
applyAll f [] = []
applyAll f [x] = [f x]
applyAll f (x :: y :: rest) =
  if x > y then f x :: f y :: applyAll f rest
  else if x == y then f x :: applyAll f rest
  else f y :: f x :: applyAll f rest

twice : (Int -> Int) -> List Int -> List Int
twice f xs =
  let ys = applyAll f xs
      zs = if length ys > 3 then applyAll f (take 3 ys) else applyAll f ys
  in zs ++ [sum ys, product (take 2 zs), cast (length xs)]

-- Forwarded two levels; the closure captures `k`.
outer : Int -> List Int -> List Int
outer k xs = twice (\x => x * k + 1) (xs ++ [k, k + 1, k * 2, k - 3])

-- Mutual forwarding: `evens` applies the closure and hands it to `odds`,
-- which only forwards it back.
mutual
  evens : (Int -> Bool) -> List Int -> List Int
  evens p [] = []
  evens p (x :: xs) =
    if p x then x :: odds p xs
    else if x > 100 then x - 100 :: odds p xs
    else if x < -100 then x + 100 :: odds p xs
    else odds p xs

  odds : (Int -> Bool) -> List Int -> List Int
  odds p [] = []
  odds p (x :: xs) =
    if x > 1000 then x :: evens p xs
    else if x < -1000 then negate x :: evens p xs
    else if x == 0 then evens p (1 :: xs)
    else evens p xs

-- Forwarded and also stored in an IORef: must stay generic.
stash : IORef (List (Int -> Int)) -> (Int -> Int) -> List Int -> IO (List Int)
stash ref f xs = do
  modifyIORef ref (f ::)
  let ys = applyAll f xs
  if length ys > 2 then pure (take 2 ys) else pure (ys ++ [f 0])

main : IO ()
main = do
  let xs = [5, 3, 9, 1, 7, 2, 8]
  printLn (sortBy compare xs)
  printLn (sort xs)
  printLn (sortBy (\a, b => compare b a) xs)
  printLn (outer 3 [1, 2, 3])
  printLn (twice (+ 1) [4, 5])
  printLn (evens (\x => x > 2) (xs ++ [1500, -2000, 0, 150]))
  ref <- newIORef []
  ys <- stash ref (+ 10) [1, 2]
  fs <- readIORef ref
  printLn (ys, map (\f => f 1) fs)
  SpecIterate.runIt
  MultiApplySpec.run
