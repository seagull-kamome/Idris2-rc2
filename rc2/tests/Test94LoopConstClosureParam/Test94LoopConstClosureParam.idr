module Main

-- A loop parameter whose initial value is a constant closure
-- (rc2/doc/inlining.md's "Fixed: constant closures and loop parameters").
-- `splitRec` becomes a self-tail loop carrying the difference list
-- `zs`, starting from `id`; once LateInline splices it into a caller
-- that passes `id` literally, `zs []` must still apply the closure the
-- loop built, not `id`. `Data.List.sort` has the same `splitRec`.

import Data.List

splitRec : List b -> List Int -> (List Int -> List Int) -> (List Int, List Int)
splitRec (_ :: _ :: xs) (y :: ys) zs = splitRec xs ys (zs . ((::) y))
splitRec _ ys zs = (ys, zs [])

main : IO ()
main = do
  printLn (splitRec [5, 3, 0, 9] [5, 3, 0, 9] id)
  printLn (sort [the Int 5, 3, 0, 9, 1])
  printLn (sortBy (flip compare) [the Int 2, 7, 1, 8, 2, 8])
