module Main

import Data.String
import System

%noinline
partial
joined : String -> String -> String -> String
joined a b c = if length a <= 1 then a ++ "-" ++ b ++ "-" ++ c else joined (strTail a) b c

%noinline
partial
mkSwapped : String -> String -> (String -> String)
mkSwapped a b = \c => joined b a c

%noinline
partial
mkRotated : String -> String -> (String -> String)
mkRotated a b = \c => joined c a b

partial
main : IO ()
main = do
  args <- getArgs
  let s = show (length args)
  let t = s ++ "t"
  let fs = [mkSwapped s t, mkSwapped t s, mkRotated s t]
  putStrLn (unwords (map (\f => f s) fs))
