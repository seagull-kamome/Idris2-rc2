module Main

-- Mutual recursion and non-tail (stack-using) recursion.

isEven : Nat -> Bool
isOdd  : Nat -> Bool

isEven Z = True
isEven (S k) = isOdd k

isOdd Z = False
isOdd (S k) = isEven k

fib : Nat -> Integer
fib Z = 0
fib (S Z) = 1
fib (S (S k)) = fib (S k) + fib k

main : IO ()
main = do
  printLn (isEven 20)
  printLn (isOdd 20)
  printLn (map fib [0,1,2,3,4,5,6,7,8,9,10,15,20])
