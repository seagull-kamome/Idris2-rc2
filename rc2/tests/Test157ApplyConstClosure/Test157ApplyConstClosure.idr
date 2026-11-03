module Main

import Data.List
import Data.SortedMap
import System

-- `fromList` folds with the constant closure of a lifted lambda that takes
-- its key first and returns a closure waiting for the map, and the fold
-- applies that closure to both arguments at once. See `check.sh` and
-- `doc/const-closure-fold.md`, "Over-application of a folded closure".

%noinline
build : Int -> SortedMap Int String
build k = fromList [(k, "a"), (k + 1, "b"), (k + 2, "c"), (k, "d")]

%noinline
weight : SortedMap Int String -> Int
weight m = foldl (\acc, (key, v) => acc + key + cast (length v)) 0 (SortedMap.toList m)

main : IO ()
main = do
  args <- getArgs
  let k = cast {to = Int} (length args)
  printLn (SortedMap.toList (build k))
  printLn (weight (build (k + 10)))
  printLn (lookup (k + 1) (build k))
