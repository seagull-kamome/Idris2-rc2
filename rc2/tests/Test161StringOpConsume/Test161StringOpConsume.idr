module Main

import Data.String
import System

%noinline
partial
living : String -> String -> String
living s t = (s ++ t) ++ s

%noinline
partial
twice : String -> String
twice s = s ++ s

%noinline
partial
mix : String -> Char -> Int -> String
mix s c i = strCons c (strTail (reverse s)) ++ singleton (strIndex s i) ++ substr 1 (cast i) s

%noinline
partial
lengthAndHead : String -> (Int, Char)
lengthAndHead s = (cast (length s), assert_total (strIndex s 0))

%noinline
partial
loop : Int -> String -> String
loop 0 acc = acc
loop n acc = loop (n - 1) (strCons 'x' (acc ++ "ab") ++ "")

partial
main : IO ()
main = do
  args <- getArgs
  let k = cast {to = Int} (length args)
  let s = "héllo" ++ show k
  putStrLn (living s "-")
  putStrLn (twice s)
  putStrLn (mix s 'z' (k + 1))
  printLn (lengthAndHead s)
  putStrLn (assert_total (loop (k + 3) ""))
  putStrLn (twice "" ++ strTail "a")
