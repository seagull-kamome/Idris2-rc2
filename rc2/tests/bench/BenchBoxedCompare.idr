module Main

-- Integer and String comparisons as loop conditions and branches: the
-- fused `cmp` over Boxed operands (doc/native-type-inference.md).
-- `base` starts past the 62-bit immediate range for the heap path.

countUp : Integer -> Integer -> Integer -> Integer
countUp i n acc = if i < n then countUp (i + 1) n (if acc == 7 then 0 else acc + 1) else acc

heapUp : Integer -> Integer -> Integer
heapUp i n = if i >= n then i else heapUp (i + 1) n

collatz : Integer -> Integer -> Integer
collatz n steps =
  if n == 1 then steps
  else if n `mod` 2 == 0 then collatz (n `div` 2) (steps + 1)
  else collatz (3 * n + 1) (steps + 1)

sumCollatz : Integer -> Integer -> Integer
sumCollatz i acc = if i > 20000 then acc else sumCollatz (i + 1) (acc + collatz i 0)

strs : List String
strs = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta"]

countLess : List String -> String -> Nat -> Nat
countLess [] _ n = n
countLess (x :: xs) p n = countLess xs p (if x < p || x == p then S n else n)

rounds : Nat -> Nat -> Nat
rounds Z acc = acc
rounds (S k) acc = rounds k (acc + countLess strs "delta" 0 + countLess strs "kappa" 0)

main : IO ()
main = do
  printLn (countUp 0 3000000 0)
  printLn (heapUp 4611686018427387904 4611686018430387904)
  printLn (sumCollatz 1 0)
  printLn (rounds 300000 0)
