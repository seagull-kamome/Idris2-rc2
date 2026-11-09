module Main

import Data.String

-- Builds and drops many short strings: each one is a String cell plus its
-- bytes (rc2/doc/constructor-layout.md, "Strings").
loop : Int -> Int -> Int
loop 0 acc = acc
loop n acc =
  let s = show n ++ "-" ++ show (n * 7)
  in loop (n - 1) (acc + cast (length s))

main : IO ()
main = printLn (loop 20000000 0)
