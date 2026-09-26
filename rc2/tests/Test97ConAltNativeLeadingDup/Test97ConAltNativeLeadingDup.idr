module Main

-- A destructured field read natively twice gets a native shadow
-- (rc2/doc/con-alt-native.md), here the heads `mergeBy compare` meets
-- once `compare` is inlined. The inner field's first read had its
-- `dup` right after the alt's `reuseOffer`; that `dup` must go with
-- the read, or every boxed element of the second list leaks. Checked
-- under valgrind. The first list's elements are summed through a loop
-- whose fields move out of a cell dropped whole, which must keep its
-- one moving `dup`.

import Data.List

upto : Int -> Int -> List Int
upto i n = if i > n then [] else i :: upto (i + 1) n

sumList : Int -> List Int -> Int
sumList acc [] = acc
sumList acc (x :: xs) = sumList (acc + x) xs

main : IO ()
main = do
  printLn (sumList 0 (mergeBy compare (upto 1 1000) (upto 1 1000)))
  printLn (take 6 (mergeBy compare [1, 4, 400, 900] [2, 300, 500, 1000]))
