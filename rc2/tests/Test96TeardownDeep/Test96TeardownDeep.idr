module Main

-- Freeing a long structure in a single drop: the runtime's teardown
-- must not recurse once per cell. Each value below is a million links
-- deep, built with an accumulator, and only its head is read before
-- the whole of it dies at once. The chains recurse through the last
-- field (a list), the first field (a SnocList) and a closure's
-- captured argument (composed functions).

build : Int -> List Int -> List Int
build 0 acc = acc
build n acc = build (n - 1) (n :: acc)

buildSnoc : Int -> SnocList Int -> SnocList Int
buildSnoc 0 acc = acc
buildSnoc n acc = buildSnoc (n - 1) (acc :< n)

compose : Int -> (Int -> Int) -> (Int -> Int)
compose 0 f = f
compose n f = compose (n - 1) (f . (+ 1))

headOr : List Int -> Int
headOr (x :: _) = x
headOr [] = 0

lastOr : SnocList Int -> Int
lastOr (_ :< x) = x
lastOr [<] = 0

main : IO ()
main = do
  let n = 1000000
  printLn (headOr (build n []))
  printLn (lastOr (buildSnoc n [<]))
  let f = compose n id
  printLn (f 0 > 0)
