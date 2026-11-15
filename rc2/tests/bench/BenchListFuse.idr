module Main

-- Chains of `map` and `filter` over a 500000-element list, and one of them followed by `++`,
-- forty times: without fusion each call makes a list the next one reads, with
-- --directive listfuse one loop makes the result (rc2/doc/list-divert.md, "Fusion").
chain : Int -> List Int
chain n = map (+ n) (filter (\x => x `mod` 3 /= 0) (map (* 2) [1 .. 500000]))

withEnd : Int -> List Int
withEnd n = map (+ 1) (filter (> n) [1 .. 500000]) ++ [n, n + 1]

go : Int -> Int -> Int
go 0 acc = acc
go n acc = go (n - 1) (acc + sum (chain n) + sum (withEnd n))

main : IO ()
main = printLn (go 40 0)
