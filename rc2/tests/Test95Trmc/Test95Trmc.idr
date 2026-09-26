module Main

-- Tail recursion modulo constructor (rc2/doc/trmc.md): each builder
-- below recurses under a constructor, a million elements deep, which
-- overflows the C stack unless it becomes a loop. Every result is
-- consumed front to back so no single drop tears down a whole list
-- (KNOWN-BUGS.md, "deep non-tail recursion": teardown still recurses).


data Chain = Link Int Chain | End

mapI : (Int -> Int) -> List Int -> List Int
mapI f [] = []
mapI f (x :: xs) = f x :: mapI f xs

-- Mixes a plain self tail call with the constructor site.
evens : List Int -> List Int
evens [] = []
evens (x :: xs) = if x `mod` 2 == 0 then x :: evens xs else evens xs

zipSum : List Int -> List Int -> List Int
zipSum (x :: xs) (y :: ys) = x + y :: zipSum xs ys
zipSum _ _ = []

upto : Int -> Int -> List Int
upto i n = if i > n then [] else i :: upto (i + 1) n

chain : Int -> Chain
chain 0 = End
chain n = Link n (chain (n - 1))

sumList : Int -> List Int -> Int
sumList acc [] = acc
sumList acc (x :: xs) = sumList (acc + x) xs

sumChain : Int -> Chain -> Int
sumChain acc End = acc
sumChain acc (Link x c) = sumChain (acc + x) c

main : IO ()
main = do
  let n = 1000000
  printLn (sumList 0 (upto 1 n))
  printLn (sumList 0 (mapI (* 2) (upto 1 n)))
  printLn (sumList 0 (evens (upto 1 n)))
  printLn (sumList 0 (zipSum (upto 1 n) (upto 1 n)))
  printLn (sumChain 0 (chain n))
  printLn (mapI (+ 1) [1, 2, 3])
  printLn (evens [])
