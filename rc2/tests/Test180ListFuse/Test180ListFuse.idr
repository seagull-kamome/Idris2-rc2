module Main

-- Chains of map/filter/mapMaybe, and `++` of one, over empty lists, lists a filter empties,
-- and a mapMaybe that drops some elements: the same results with and without
-- --directive listfuse (rc2/doc/list-divert.md, "Fusion").

mm : List Int -> List Int
mm xs = map (+ 1) (map (* 2) xs)

mf : List Int -> List Int
mf xs = filter (> 3) (map (* 2) xs)

fm : List Int -> List Int
fm xs = map (+ 1) (filter (> 3) xs)

ff : List Int -> List Int
ff xs = filter (< 8) (filter (> 3) xs)

three : List Int -> List Int
three xs = map (+ 100) (filter (\x => x `mod` 3 /= 0) (map (* 2) xs))

jj : List Int -> List Int
jj xs = mapMaybe (\x => if x > 4 then Just (x * 10) else Nothing) (map (+ 1) xs)

jf : List Int -> List Int
jf xs = filter (> 50) (mapMaybe (\x => if x > 4 then Just (x * 10) else Nothing) xs)

mEnd : List Int -> List Int -> List Int
mEnd xs ys = map (+ 1) xs ++ ys

cEnd : List Int -> List Int -> List Int
cEnd xs ys = map (+ 1) (filter (> 2) xs) ++ ys

-- the result of one fused loop is the list another reads
nested : List Int -> List Int
nested xs = map (* 3) (mEnd xs [10, 20])

-- a list given twice: no sharing of the intermediate one is assumed
twice : List Int -> (List Int, List Int)
twice xs = let ys = map (+ 1) xs in (map (* 2) ys, filter (> 3) ys)

-- a fold or `length` of a chain: the list is not built
sm : List Int -> Int
sm xs = sum (map (* 2) xs)

ln : List Int -> Nat
ln xs = length (filter (> 3) xs)

-- order matters: building a list with the folds' own order
fl : List Int -> List Int
fl xs = foldl (\acc, x => x :: acc) [] (filter (> 2) (map (+ 1) xs))

fr : List Int -> List Int
fr xs = foldr (\x, acc => x :: acc) [] (map (+ 1) (filter (> 2) xs))

jl : List Int -> Nat
jl xs = length (mapMaybe (\x => if x > 4 then Just x else Nothing) (map (+ 1) xs))

main : IO ()
main = do
  let xs : List Int = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
  let nilInts : List Int = []
  let allDropped : List Int = [1, 1, 1]
  for_ [xs, nilInts, allDropped] $ \l => do
    printLn (mm l)
    printLn (mf l)
    printLn (fm l)
    printLn (ff l)
    printLn (three l)
    printLn (jj l)
    printLn (jf l)
    printLn (mEnd l [7, 8])
    printLn (cEnd l [7, 8])
    printLn (cEnd l nilInts)
    printLn (nested l)
    printLn (twice l)
    printLn (sm l)
    printLn (ln l)
    printLn (fl l)
    printLn (fr l)
    printLn (jl l)
