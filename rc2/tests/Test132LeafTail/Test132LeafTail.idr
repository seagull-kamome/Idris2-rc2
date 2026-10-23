module Main

-- Direct tail calls to leaf functions (`Compiler.RC2.LeafTail`,
-- `doc/leaf-tail-calls.md`): forwarders that only tail-call a function
-- returning a constructor, next to `ping` and `pong`, which tail-call each
-- other. A cycle is not a leaf, and a million bounces must still run in
-- constant C stack. The answers are what an output diff can see; the shape
-- of the code is in the doc.

%noinline
leaf : Int -> List Int
leaf a = [a, a + 1]

%noinline
fwd : Int -> List Int
fwd a = leaf a

%noinline
fwd2 : Int -> List Int
fwd2 a = fwd (a * 2)

mutual
  %noinline
  ping : Int -> Int -> Int
  ping 0 acc = acc
  ping n acc = pong (n - 1) (acc + sum (fwd2 n))

  %noinline
  pong : Int -> Int -> Int
  pong 0 acc = acc
  pong n acc = ping (n - 1) (acc + 1)

main : IO ()
main = do
  printLn (fwd 3)
  printLn (fwd2 5)
  printLn (ping 1000000 0)
