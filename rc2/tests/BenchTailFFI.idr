module Main

-- Measures Compiler.RC2.DualABI's Stage 4b (rc2/doc/dual-abi.md): a
-- function whose entire body is a tail call straight into a %foreign
-- declaration used to be deferred through the same boxed
-- closure/trampoline scheme as an ordinary RC2-to-RC2 tail call, even
-- though prim__labs is a leaf as far as that scheme's own stack-depth
-- concern is concerned. tailAbs's own body is exactly that shape; the
-- surrounding loop calls it a few million times so the per-call
-- closure-build overhead (before this fix) shows up in wall clock.

%foreign "C:labs,libc,stdlib.h"
prim__labs : Int -> Int

tailAbs : Int -> Int
tailAbs n = prim__labs n

loop : Int -> Int -> Int
loop 0 acc = acc
loop n acc = loop (n - 1) (acc + tailAbs (n - 2500000))

main : IO ()
main = printLn (loop 5000000 0)
