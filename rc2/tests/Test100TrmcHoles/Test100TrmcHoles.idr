module Main

-- TRMC phase 3 (rc2/doc/trmc.md): holes at different field indexes in
-- one function, and sites with more than one recursive field. Each
-- builder below goes a million deep, which overflows the C stack
-- unless it becomes a loop. `mapT` over `Leaf` also covers a reuse offer
-- on a field-less constructor, which crashed on a folded constant `Leaf`
-- (a tagged pointer, not a cell).

data Alt = A Int Alt | B Alt Int | Stop

data Tree = Leaf | Node Tree Int Tree

-- The hole is field 1 of `A` but field 0 of `B`.
alternate : Int -> Alt
alternate 0 = Stop
alternate n = if n `mod` 2 == 0 then A n (alternate (n - 1)) else B (alternate (n - 1)) n

-- Both subtrees recurse; only the right one, evaluated last, is the hole.
mapT : (Int -> Int) -> Tree -> Tree
mapT f Leaf = Leaf
mapT f (Node l x r) = Node (mapT f l) (f x) (mapT f r)

sumAlt : Int -> Alt -> Int
sumAlt acc Stop = acc
sumAlt acc (A x r) = sumAlt (acc + x) r
sumAlt acc (B r x) = sumAlt (acc + x) r

countAs : Int -> Alt -> Int
countAs acc Stop = acc
countAs acc (A _ r) = countAs (acc + 1) r
countAs acc (B r _) = countAs acc r

rightSpine : Int -> Tree -> Tree
rightSpine 0 acc = acc
rightSpine n acc = rightSpine (n - 1) (Node Leaf n acc)

balanced : Int -> Int -> Tree
balanced lo hi =
  if lo > hi then Leaf
  else let mid = (lo + hi) `div` 2 in Node (balanced lo (mid - 1)) mid (balanced (mid + 1) hi)

sumT : Int -> List Tree -> Int
sumT acc [] = acc
sumT acc (Leaf :: ts) = sumT acc ts
sumT acc (Node l x r :: ts) = sumT (acc + x) (l :: r :: ts)

inorder : Tree -> List Int
inorder Leaf = []
inorder (Node l x r) = inorder l ++ x :: inorder r

main : IO ()
main = do
  let big = 1000000
  let alt = alternate big
  printLn (sumAlt 0 alt, countAs 0 alt)
  let t = mapT (* 2) (rightSpine big Leaf)
  printLn (sumT 0 [t])
  printLn (inorder (mapT (+ 100) (balanced 1 15)))
