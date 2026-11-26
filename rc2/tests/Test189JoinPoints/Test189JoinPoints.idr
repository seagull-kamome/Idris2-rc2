module Main

import System

-- rc2/doc/join-points.md: tails written out twice become jumps to one
-- join point. In `walk` the copies end in the recursive call, which Loop
-- makes a `continue`, so the join point is inside the loop; `finish` has
-- no loop. `acc` and `m` are native Ints passed as native parameters.

%noinline
walk : Int -> Int -> Int -> Int
walk 0 _ acc = acc
walk n m acc = case mod n 3 of
  0 => walk (n - 1) (m + 1) (acc + n * m + 3 * (m - n) + 7 * (n + m) - (acc `div` 7))
  1 => walk (n - 1) m (acc + 1)
  _ => walk (n - 1) (m + 1) (acc + n * m + 3 * (m - n) + 7 * (n + m) - (acc `div` 7))

%noinline
finish : Int -> Int -> String
finish a b = case compare a b of
  LT => "r" ++ show (a - b)
  EQ => "e" ++ show a
  GT => "r" ++ show (a - b)

main : IO ()
main = do
  k <- cast . length <$> getArgs
  printLn (walk (20 * k) (3 * k) (k - 1))
  traverse_ (\(a, b) => putStrLn (finish (a * k) (b * k))) [(1, 2), (2, 2), (5, 3)]
