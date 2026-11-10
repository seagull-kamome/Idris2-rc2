module Main

import Data.List

-- Builds, maps, filters and drops a 300000-element list fifty times: almost
-- every allocation is a `::` cell that dies a step later
-- (rc2/doc/small-object-allocator.md).
go : Int -> Int -> Int
go 0 acc = acc
go n acc = go (n - 1) (acc + sum (filter (\x => x `mod` 2 == 0) (map (+ n) [1 .. 300000])))

main : IO ()
main = printLn (go 50 0)
