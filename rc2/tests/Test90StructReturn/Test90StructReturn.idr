module Main

-- Struct return (rc2/doc/struct-return.md). verify.sh checks which
-- workers return a struct in the dump; the output itself is diffed against
-- refc.

-- Every level cases on the level below and rebuilds the same Either:
-- eligible (a one-field constructor in every tail), and its own
-- recursive call is a site that gains. Every `Right` carries a native
-- `Int`, so the struct holds it unboxed (`Ret1:1=Int`); `step 4 1000`
-- returns values past the small-int cache, which would each need a box.
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

-- A two-field constructor in every tail, switched on by its own
-- recursive call: both fields Boxed (`Ret2`).
halves : List Int -> (List Int, List Int)
halves [] = ([], [])
halves (x :: xs) = let (l, r) = halves xs in (x :: r, l)

-- Both fields native Ints (`Ret2:1=Int,Int`: `MkPair` is tag 1).
qr : Int -> Int -> Int -> (Int, Int)
qr q a b = if a < b then (q, a) else qr (q + 1) (a - b) b

quotient : Int -> Int -> Int
quotient a b = case qr 0 a b of (q, _) => q

remainder : Int -> Int -> Int
remainder a b = case qr 0 a b of (_, r) => r

data Shape = Dot | Seg Int Int | Tri Int Int Int

-- Two fields wide by itself, but `shapeOf` tail-calls it and returns
-- a three-field `Tri` too: both share one three-field struct
-- (`Ret3:1=Int,Int,Boxed:2=Int,Int,Int`), `Seg`'s third field unused.
segOf : Int -> Shape
segOf n = if n > 10 then segOf (n - 10) else if n < 0 then Dot else Seg n (n * 2)

shapeOf : Int -> Shape
shapeOf n = if n > 100 then Tri n (n + 1) (n + 2) else segOf n

measure : Int -> Int
measure n = case shapeOf n of
              Dot => 0
              Seg a b => a * b
              Tri a b c => a + b + c

segLength : Int -> Int
segLength n = case segOf n of
                Seg a b => b - a
                _ => -1

measureTwice : Int -> Int
measureTwice n = case shapeOf n of
                   Tri a _ c => c - a
                   _ => measure (n + 1)

main : IO ()
main = do
  printLn (step 3 10)
  printLn (step 2 (-5))
  printLn (step 4 1000)
  putStrLn (describe "b" [("a", 1), ("b", 2)])
  putStrLn (describe "z" [("a", 1)])
  printLn (known "a" [("a", 1)])
  printLn (map halfOf [1, 2, 3, 4])
  printLn (map halfOf [10, 11])
  printLn (halves [1, 2, 3, 4, 5])
  printLn (quotient 17 5, remainder 17 5, quotient 3 7, remainder 3 7)
  printLn (map measure [-3, 4, 25, 250])
  printLn (map segLength [-1, 7, 33])
  printLn (measureTwice 5, measureTwice 500)
