module Main

import Data.IORef

fact : Nat -> Integer
fact Z = 1
fact (S k) = cast (S k) * fact k

sumList : List Int -> Int
sumList [] = 0
sumList (x :: xs) = x + sumList xs

loop : Int -> Int -> Int
loop acc 0 = acc
loop acc n = loop (acc + n) (n - 1)

main : IO ()
main = do
  putStrLn ("fact 10 = " ++ show (fact 10))
  printLn (fact 10)
  printLn (sumList [1,2,3,4,5])
  printLn (loop 0 100000)
  ref <- newIORef 0
  modifyIORef ref (+1)
  modifyIORef ref (+41)
  v <- readIORef ref
  printLn v
  putStrLn (reverse "Hello, RC2!")
  let xs = [1..10]
  printLn (map (*2) xs)
  printLn (filter (\x => mod x 2 == 0) xs)
