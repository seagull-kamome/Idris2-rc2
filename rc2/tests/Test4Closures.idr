module Main

-- Closures, higher-order functions, partial application: exercises the
-- boxed/escaping path (functions captured as first-class values become
-- RUnderApp/closures at the ANF level, always boxed in this backend).

add3 : Int -> Int -> Int -> Int
add3 a b c = a + b + c

makeAdder : Int -> (Int -> Int)
makeAdder n = \x => x + n

compose2 : (b -> c) -> (a -> b) -> a -> c
compose2 f g = \x => f (g x)

main : IO ()
main = do
  let partial1 = add3 1
  let partial2 = partial1 2
  printLn (partial2 3)

  let adders = map makeAdder [1,2,3,4,5]
  printLn (map (\f => f 100) adders)

  let pipeline = compose2 (*2) (+1)
  printLn (map pipeline [1,2,3,4,5])

  printLn (foldl (\acc, x => acc ++ [x * x]) [] [1,2,3,4,5])
  printLn (sum (map (\x => x * x) [1..10]))
