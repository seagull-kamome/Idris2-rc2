module Main

import Data.List

-- Sorts a million pseudo-random Ints with Data.List.sort, a merge sort that
-- allocates and drops list cells throughout (rc2/doc/small-object-allocator.md).
rnd : Int -> List Int -> Int -> List Int
rnd 0 acc _ = acc
rnd n acc s = let s' = (s * 1103515245 + 12345) `mod` 2147483648 in rnd (n - 1) (s' :: acc) s'

main : IO ()
main = printLn (sum (take 10 (sort (rnd 1000000 [] 42))))
