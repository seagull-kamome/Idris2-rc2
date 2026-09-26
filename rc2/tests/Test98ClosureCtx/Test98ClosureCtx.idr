module Main

-- Difference lists carried by a self-recursive function
-- (rc2/doc/closure-accumulator.md): `c . (y ::)` becomes a chain of
-- cells with an open hole. `sort` splits with exactly this, a million
-- elements deep; the rest cover a start other than `id`, one
-- application per branch, and a context applied twice on one path,
-- which must be left as closures.

import Data.List

splitRec : List b -> List Int -> (List Int -> List Int) -> (List Int, List Int)
splitRec (_ :: _ :: xs) (y :: ys) zs = splitRec xs ys (zs . ((::) y))
splitRec _ ys zs = (ys, zs [])

evensThen : List Int -> (List Int -> List Int) -> List Int
evensThen [] c = c [100]
evensThen (x :: xs) c =
  if x `mod` 2 == 0 then evensThen xs (c . ((::) x)) else evensThen xs c

branches : Bool -> List Int -> (List Int -> List Int) -> List Int
branches b [] c = if b then c [1] else c [2]
branches b (x :: xs) c = branches b xs (c . ((::) x))

twice : List Int -> (List Int -> List Int) -> (List Int, List Int)
twice [] c = (c [0], c [9])
twice (x :: xs) c = twice xs (c . ((::) x))

gen : Int -> Int -> List Int -> List Int
gen 0 _ acc = acc
gen n s acc = let s' = (s * 1103515245 + 12345) `mod` 2147483648 in gen (n - 1) s' (s' :: acc)

main : IO ()
main = do
  printLn (splitRec [5, 3, 0, 9, 7] [5, 3, 0, 9, 7] id)
  let ys = sort (gen 1000000 42 [])
  printLn (length ys, take 3 ys)
  printLn (evensThen [1, 2, 3, 4, 5, 6] (\xs => 7 :: xs))
  printLn (branches True [1, 2, 3] id, branches False [4, 5] reverse)
  printLn (twice [1, 2, 3] id)
