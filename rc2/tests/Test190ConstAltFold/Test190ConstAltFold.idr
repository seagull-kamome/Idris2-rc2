module Main

import System

-- In a constant-case alt the scrutinee is its constant, so a comparison
-- of it folds; a comparison of a local with itself folds too, but for a
-- Double `==` (NaN), and a Double matching 0.0 may be -0.0.

%noinline
sign : Int -> String
sign n = case n of
  0 => "zero"
  -2 => if n >= 0 then "bad" else "minus two"
  _ => if n == n then (if n < n then "bad" else "other") else "never"

%noinline
dsign : Double -> String
dsign x = case x of
  0.0 => "zero " ++ show (1.0 / x)
  2.5 => if x > 1.0 then "big" else "small"
  _ => if x == x then "num" else "nan"

-- An Integer too big for the pointer word keeps its local (a literal would
-- be a fresh mpz at each use), so only the small alt's comparison folds.
%noinline
isig : Integer -> String
isig n = case n of
  100000000000000000000 => if n > 5 then "huge " ++ show n else "bad"
  7 => if n == 7 then "seven " ++ show (n + 1) else "bad"
  _ => "other"

main : IO ()
main = do
  traverse_ (putStrLn . sign) [0, -2, 5]
  traverse_ (putStrLn . dsign) [0.0, -0.0, 2.5, 1.0, 0.0 / 0.0]
  -- One factor known only at run time, so no call site folds.
  k <- cast . length <$> getArgs
  traverse_ (putStrLn . isig . (* k)) [100000000000000000000, 7, 3]
