module Main

add3 : Int -> Int -> Int -> Int
add3 a b c = a + b + c

loopChain : Int -> Int -> Int
loopChain acc 0 = acc
loopChain acc n =
  let f = add3 n
      g = f (n + 1)
  in loopChain (acc + g (n + 2)) (n - 1)

main : IO ()
main = printLn (loopChain 0 3000000)
