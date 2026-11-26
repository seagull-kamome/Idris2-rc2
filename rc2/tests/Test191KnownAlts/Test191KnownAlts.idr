module Main

-- rc2/doc/const-caf-fold.md, "Constant-case alts": a case again on a
-- local an enclosing case matched takes the alt of its constructor, or
-- loses the alts its default is past; `==` against such a constant is false.

import System

data T = A Int | B Int Int | C

-- A case again on the same local inside its alt, and inside its default.
%noinline
again : T -> Int
again t = case t of
  A x => case t of
           A y => x + y
           B y z => 100 + y + z
           C => 200
  _ => case t of
         A y => 300 + y
         B y z => y * z
         C => -1

%noinline
digit : Int -> String
digit n = case n of
  0 => "zero"
  1 => "one"
  _ => if n == 0 then "bad" else case n of
                                    1 => "bad"
                                    2 => "two"
                                    _ => "many"

main : IO ()
main = do
  k <- cast . length <$> getArgs
  traverse_ (printLn . again) [A (k * 3), B (k * 4) (k * 5), C]
  traverse_ (putStrLn . digit . (* k)) [0, 1, 2, 3]
