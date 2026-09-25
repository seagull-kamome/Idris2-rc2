module Main

-- Struct return (rc2/doc/struct-return.md). verify.sh checks which
-- workers return `Ret1` in the dump; the output itself is diffed against
-- refc.

-- Every level cases on the level below and rebuilds the same Either:
-- eligible (a one-field constructor in every tail), and its own
-- recursive call is a site that gains.
step : Int -> Int -> Either String Int
step 0 x = if x < 0 then Left "neg" else Right x
step d x = case step (d - 1) (x + 1) of
             Left e => Left e
             Right v => Right (v + 1)

-- A `Nothing` tail is `RCNull` in the IR: accepted, next to `Just`.
-- `describe` and `known` switch on its result straight away (two callers,
-- so it is not inlined), so it keeps a worker.
lookupAge : String -> List (String, Int) -> Maybe Int
lookupAge _ [] = Nothing
lookupAge k ((n, a) :: rest) = if k == n then Just a else lookupAge k rest

describe : String -> List (String, Int) -> String
describe k xs = case lookupAge k xs of
                  Nothing => k ++ ": unknown"
                  Just a => k ++ ": " ++ show a

known : String -> List (String, Int) -> Bool
known k xs = case lookupAge k xs of
               Nothing => False
               Just _ => True

-- Eligible, but only ever called as `map`'s argument, i.e. as a closure
-- (twice, so it is not inlined): no caller gains, so it keeps no worker.
halfOf : Int -> Maybe Int
halfOf x = if mod x 2 == 0 then Just (div x 2) else Nothing

-- A two-field constructor in a tail: not eligible.
halves : List Int -> (List Int, List Int)
halves [] = ([], [])
halves (x :: xs) = let (l, r) = halves xs in (x :: r, l)

main : IO ()
main = do
  printLn (step 3 10)
  printLn (step 2 (-5))
  putStrLn (describe "b" [("a", 1), ("b", 2)])
  putStrLn (describe "z" [("a", 1)])
  printLn (known "a" [("a", 1)])
  printLn (map halfOf [1, 2, 3, 4])
  printLn (map halfOf [10, 11])
  printLn (halves [1, 2, 3, 4, 5])
