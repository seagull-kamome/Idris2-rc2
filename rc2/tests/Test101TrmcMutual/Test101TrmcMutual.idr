module Main

-- TRMC phase 2 (rc2/doc/trmc.md): recursion under a constructor that
-- goes through another function. Each builder below goes a million
-- deep, which overflows the C stack unless the group becomes one loop.
-- The helpers are too big for Inline to fold them into their caller.
-- `sumE` also covers ConstFold folding a `case` over a NULL (`Nothing`)
-- field of a known pair, which once left an undeclared C local.

mutual
  data E = Node Int Opt

  -- The recursive field sits at a different index in each constructor.
  data Opt = Stop | One E | Two Int E | Three Int Int E

mutual
  -- The helper pattern: `runs` only tail-calls `step`, and `step`
  -- builds `x :: runs xs`.
  runs : List Int -> List Int
  runs [] = []
  runs (x :: xs) = step x xs

  step : Int -> List Int -> List Int
  step x xs =
    if x `mod` 3 == 0 then runs xs
    else if x `mod` 5 == 0 then x * 3 :: runs xs
    else if x `mod` 7 == 0 then (x + 1) :: runs xs
    else if x `mod` 11 == 0 then (x - 1) * 5 :: runs xs
    else x * 2 :: runs xs

mutual
  mapE : E -> E
  mapE (Node x o) = Node (x * 2) (mapOpt o)

  mapOpt : Opt -> Opt
  mapOpt Stop = Stop
  mapOpt (One e) = One (mapE e)
  mapOpt (Two i e) = Two (i * 3 + 1) (mapE e)
  mapOpt (Three i j e) = Three (i + j) (i * j - 7) (mapE e)

buildE : Int -> E -> E
buildE 0 acc = acc
buildE n acc =
  let o = case n `mod` 3 of
            0 => One acc
            1 => Two n acc
            _ => Three n 2 acc
  in buildE (n - 1) (Node n o)

sumOpt : Int -> Opt -> (Int, Maybe E)
sumOpt acc Stop = (acc, Nothing)
sumOpt acc (One e) = (acc, Just e)
sumOpt acc (Two i e) = (acc + i, Just e)
sumOpt acc (Three i j e) = (acc + i + j, Just e)

sumE : Int -> E -> Int
sumE acc (Node x o) = case sumOpt (acc + x) o of
  (acc', Nothing) => acc'
  (acc', Just e) => sumE acc' e

sumList : Int -> List Int -> Int
sumList acc [] = acc
sumList acc (x :: xs) = sumList (acc + x) xs

upto : Int -> List Int -> List Int
upto 0 acc = acc
upto n acc = upto (n - 1) (n :: acc)

main : IO ()
main = do
  let big = 1000000
  let rs = runs (upto big [])
  printLn (sumList 0 rs, length rs)
  printLn (sumE 0 (mapE (buildE big (Node 0 Stop))))
