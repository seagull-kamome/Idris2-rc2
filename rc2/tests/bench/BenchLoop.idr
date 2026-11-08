module Main

sumTo : Int -> Int -> Int
sumTo acc 0 = acc
sumTo acc n = sumTo (acc + n) (n - 1)

main : IO ()
main = printLn (sumTo 0 3000000)
