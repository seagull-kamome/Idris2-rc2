module Main

-- Two functions that call each other in tail position: `MutualLoop` merges them into one function and
-- leaves each a one-line wrapper that calls it with a selector and the padding of the parameters it
-- lacks. `FwdAlias` makes the calls of a wrapper calls of the merged function
-- (rc2/doc/fwd-alias.md, "Constants added"); check.sh counts them in the IR.

import System

mutual
  %noinline
  ping : Int -> Int -> Int
  ping 0 acc = acc
  ping n acc = pong (n - 1) (acc + 1)

  %noinline
  pong : Int -> Int -> Int
  pong 0 acc = acc
  pong n acc = ping (n - 1) (acc + 2)

main : IO ()
main = do
  args <- getArgs
  let k = cast (length args)
  printLn (ping (k + 999999) 0)
  printLn (pong (k + 1000000) 5)
  printLn (ping (k + 11) 100 + pong (k + 12) 200)
