module Main

import System

-- A loop with no exit, bound by a `let` whose body still names the
-- result: the result variable must be declared even though nothing
-- ever assigns it. Only reached with more than five arguments, so
-- the test itself never hangs.
spin : Int -> Int
spin x = spin (x + 1)

main : IO ()
main = do
  args <- getArgs
  if length args > 5
     then printLn (spin 0)
     else putStrLn "ok"
