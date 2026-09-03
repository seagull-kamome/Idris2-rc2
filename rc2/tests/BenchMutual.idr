module Main

-- Mutual tail recursion throughput, same total iteration count as
-- BenchLoop.idr's sumTo, but split across two functions that tail-call
-- each other on every step -- exercises Compiler.RC2.MutualLoop's
-- merge+goto conversion under a real timing workload (Test9SelfTailLoop.idr,
-- which absorbed the former Test10MutualLoop.idr, already covers
-- correctness/edge cases).

pingPong : Int -> Int -> Int
pongPing : Int -> Int -> Int

pingPong 0 acc = acc
pingPong n acc = pongPing (n - 1) (acc + n)

pongPing 0 acc = acc
pongPing n acc = pingPong (n - 1) (acc + n)

main : IO ()
main = printLn (pingPong 3000000 0)
