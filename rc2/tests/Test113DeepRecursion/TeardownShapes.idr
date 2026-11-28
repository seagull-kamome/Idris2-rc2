module Test113DeepRecursion.TeardownShapes

-- Freeing a long structure whose cells hold other heap values: the
-- runtime's teardown must not recurse once per cell whichever field the
-- chain runs through. Each value is a million links deep and dies in one
-- drop after its head is read (as in TeardownDeep). Before, teardown
-- looped on the first dying field with children and recursed on the
-- others, so these took a C frame per link (a list of pairs overflowed
-- an 8 MB stack at about 200,000), and an IORef's value was dropped by a
-- recursive call.

import Data.IORef

pairs : Int -> List (Int, Int) -> List (Int, Int)
pairs 0 acc = acc
pairs n acc = pairs (n - 1) ((n, n) :: acc)

snocPairs : Int -> SnocList (Int, Int) -> SnocList (Int, Int)
snocPairs 0 acc = acc
snocPairs n acc = snocPairs (n - 1) (acc :< (n, n))

lists : Int -> List (List Int) -> List (List Int)
lists 0 acc = acc
lists n acc = lists (n - 1) ([n] :: acc)

data Chain = End | Link Int (IORef Chain)

-- A spine whose cells hold children before the last field: a constructor
-- with three such fields, a closure, a lazy value and an IORef, and a
-- subtree shared by every cell, which must survive the spine's drop.
data Mixed = Leaf Int
           | Three Mixed (List Int) Mixed
           | WithFn (Int -> Int) Mixed
           | WithLazy (Lazy Mixed) Mixed
           | WithRef (IORef Mixed) Mixed

mixed : Int -> Mixed -> Mixed -> IO Mixed
mixed 0 _ acc = pure acc
mixed k shared acc = do
  r <- newIORef (Leaf k)
  let cell = case k `mod` 4 of
               0 => Three (Three (Leaf k) [k, k] shared) [k] acc
               1 => WithFn (\x => x + k) acc
               2 => WithLazy (Delay (Three (Leaf k) [] (Leaf 1))) acc
               _ => WithRef r acc
  mixed (k - 1) shared cell

sumMixed : Mixed -> Int
sumMixed (Leaf k) = k
sumMixed (Three a xs b) = sumMixed a + foldl (+) 0 xs + sumMixed b
sumMixed _ = 0

kindOf : Mixed -> Int
kindOf (Leaf k) = k
kindOf (Three _ _ _) = 0
kindOf (WithFn f _) = f 0
kindOf (WithLazy _ _) = 2
kindOf (WithRef _ _) = 3

chain : Int -> Chain -> IO Chain
chain 0 c = pure c
chain n c = do
  r <- newIORef c
  chain (n - 1) (Link n r)

firstPair : List (Int, Int) -> Int
firstPair ((a, _) :: _) = a
firstPair [] = 0

lastPair : SnocList (Int, Int) -> Int
lastPair (_ :< (a, _)) = a
lastPair [<] = 0

firstList : List (List Int) -> Int
firstList ((x :: _) :: _) = x
firstList _ = 0

linkOf : Chain -> Int
linkOf (Link k _) = k
linkOf End = 0

export
run : IO ()
run = do
  let n = 1000000
  printLn (firstPair (pairs n []))
  printLn (lastPair (snocPairs n [<]))
  printLn (firstList (lists n []))
  c <- chain n End
  printLn (linkOf c)
  let shared = Three (Leaf 7) [1, 2, 3] (Leaf 8)
  m <- mixed n shared (Leaf 0)
  printLn (kindOf m)
  printLn (sumMixed shared)
