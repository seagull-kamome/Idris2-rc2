module Main

-- Struct return (rc2/doc/struct-return.md). Step 1 only computes which
-- functions may return by value; verify.sh checks the `.dualabi` marks.
-- The output itself is just diffed against refc.

%cg rc2 dumpdualabi

-- Every level cases on the level below and rebuilds the same Either:
-- eligible (a one-field constructor in every tail).
step : Int -> Int -> Either String Int
step 0 x = if x < 0 then Left "neg" else Right x
step d x = case step (d - 1) (x + 1) of
             Left e => Left e
             Right v => Right (v + 1)

-- A `Nothing` tail is `RCNull` in the IR: accepted, next to `Just`.
lookupAge : String -> List (String, Int) -> Maybe Int
lookupAge _ [] = Nothing
lookupAge k ((n, a) :: rest) = if k == n then Just a else lookupAge k rest

-- A two-field constructor in a tail: not eligible.
halves : List Int -> (List Int, List Int)
halves [] = ([], [])
halves (x :: xs) = let (l, r) = halves xs in (x :: r, l)

main : IO ()
main = do
  printLn (step 3 10)
  printLn (step 2 (-5))
  printLn (lookupAge "b" [("a", 1), ("b", 2)])
  printLn (lookupAge "z" [("a", 1)])
  printLn (halves [1, 2, 3, 4, 5])
