module Main

import System

%noinline
loopy : Int -> Int -> Int
loopy 0 acc = acc
loopy n acc = loopy (n - 1) (acc + n)

%noinline
viaLoop : Int -> Int
viaLoop n = loopy n 0

%noinline
fwdLoop : Int -> Int
fwdLoop n = viaLoop (n + 1)

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
  printLn (fwdLoop (k + 100))
  printLn (ping (k + 999999) 0)
