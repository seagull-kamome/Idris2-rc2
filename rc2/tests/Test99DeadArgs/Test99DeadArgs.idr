module Main

-- Dead argument elimination (rc2/doc/dead-args.md): `where` functions
-- receive the enclosing clause's variables whether they use them or
-- not. `countEvens`'s helper only carries `xs` and `tag` along, so
-- they must be removed; kept, the loop would hold `xs`'s head and turn
-- every cell shared. `hop`/`skip` forward a dead argument to each
-- other; `scaled` has a dead argument but is also used as a partial
-- application, so its signature must stay. `sort` is the motivating
-- case (Data.List's `split`), under valgrind.

import Data.List

countEvens : String -> List Int -> Int
countEvens tag xs = go xs 0
  where
    go : List Int -> Int -> Int
    go [] acc = acc
    go (y :: ys) acc = go ys (if y `mod` 2 == 0 then acc + 1 else acc)

hop : List Int -> Int -> Int -> Int
skip : List Int -> Int -> Int -> Int

hop junk 0 acc = acc
hop junk n acc = skip junk (n - 1) (acc + 2)

skip junk 0 acc = acc
skip junk n acc = hop junk (n - 1) (acc + 1)

scaled : Int -> Int -> Int -> Int
scaled unused k x = k * x

upto : Int -> Int -> List Int
upto i n = if i > n then [] else i :: upto (i + 1) n

main : IO ()
main = do
  printLn (countEvens "evens" (upto 1 100000))
  printLn (hop (upto 1 1000) 10 0)
  printLn (map (scaled 99 3) [1, 2, 3])
  let big = upto 1 10
  printLn (hop (map (* 2) big) 7 (cast (length big)))
  printLn (take 5 (sort [the Int 5, 3, 9, 1, 7, 2, 8]))
