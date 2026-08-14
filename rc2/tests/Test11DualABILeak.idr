module Main

-- Regression test for a real reference leak found in
-- Compiler.RC2.DualABI's worker/wrapper synthesis (see
-- rc2/doc/dual-abi.md's own "Bugs found and fixed" section): a
-- dual-ABI wrapper reading one of its own Boxed parameters natively
-- (`rcVarToNativeC`, which never dups/drops on its own) left that
-- parameter's own reference alive with nothing to ever drop it.
-- `fib`/`sumTo` never surfaced this in the existing benchmark suite
-- because every value they promote to native stays within the
-- small-int cache range ([0,100), immortal, so a missing drop is a
-- silent no-op there) -- `dbl`'s own argument here is deliberately
-- pushed well outside that range so a real heap allocation, and a
-- real leak if the bug ever comes back, is unavoidable.
--
-- This test's own stdout output can't detect the bug at all (a leak
-- doesn't corrupt any computed value) -- verify with:
--   valgrind --leak-check=full ./build/exec/<this test's own output>
-- and expect "definitely lost: 0 bytes in 0 blocks" (only the 100
-- small-int-cache entries, "still reachable", are expected).

dbl : Int -> Int
dbl n = let a = n - 1
            b = n - 2 in
            a + b + 3

loop : Int -> Int -> Int
loop 0 acc = acc
loop n acc = loop (n - 1) (acc + dbl (n + 1000000))

main : IO ()
main = printLn (loop 200000 0)
