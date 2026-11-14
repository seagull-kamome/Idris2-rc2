module Main

-- A `Char` read out of a string (`strIndex`, `strHead`) and a cast to a small type are
-- immediates although the op runs on the boxed path, so the local holding one gets no
-- dup/drop (rc2/doc/native-type-inference.md, "Always-unboxed locals"). check.sh looks
-- for a drop of such a local in the IR; the shape is Levenshtein's: the Char is passed to a
-- call and compared after.

import Data.String
import System

-- strIndex is partial upstream
%default partial

%noinline
isAlphaBoxed : Char -> Bool
isAlphaBoxed c = isAlpha c

%noinline
score : String -> String -> Int -> Int -> Int
score a b i j =
  let x = strIndex a i
      y = strIndex b j
  in if x == y then 0
     else if isAlphaBoxed x && isAlphaBoxed y then 1
     else if x >= '0' && x <= '9' && y >= '0' && y <= '9' then 1
     else 2

%noinline
small : Integer -> Bits8
small n = cast n

main : IO ()
main = do
  args <- getArgs
  let k = cast (length args)
  printLn (score "kitten" "sitting" k (k + 1))
  printLn (score "a1b2" "a3b4" (k + 1) (k + 1))
  printLn (score "x-y" "x_y" (k + 1) (k + 1))
  printLn (small (cast k + 300))
  printLn (prim__strHead ("q" ++ show k))
