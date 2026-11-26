module Main

-- rc2/doc/join-points.md: the fallback clauses the case tree copies
-- into each alt become jumps to one join point.

-- Nested patterns with fallback clauses: the case tree copies the later
-- clauses into every alt that does not match, and the recursion is a loop.
walk : List Int -> List Int -> Int -> Int
walk (1 :: xs) (2 :: ys) acc = walk xs ys (acc + 1)
walk (3 :: xs) ys acc = walk xs ys (acc * 2)
walk xs (4 :: ys) acc = walk xs ys (acc - 1)
walk (x :: xs) (y :: ys) acc = walk xs ys (acc + x * y)
walk _ _ acc = acc

-- The same outside a loop.
classify : List Int -> List Int -> Int -> String
classify (1 :: _) (2 :: _) n = "a" ++ show n
classify (3 :: _) _ n = "b" ++ show (n * 2)
classify _ (4 :: _) n = "c" ++ show (n - 1)
classify (x :: _) (y :: _) n = "d" ++ show (x + y + n)
classify _ _ n = "e" ++ show n

main : IO ()
main = do
  printLn (walk [1, 3, 5, 7, 1, 9] [2, 4, 6, 4, 8, 2] 10)
  printLn (walk [5, 6, 7] [4, 4] 0)
  traverse_ (\(a, b) => putStrLn (classify a b 7))
    [([1], [2]), ([3], [9]), ([5], [4]), ([5], [6]), ([], [4]), ([], []), ([1], [5]), ([3], [])]
