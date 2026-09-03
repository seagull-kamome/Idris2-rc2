module Main

-- Measures Compiler.RC2.Loop's call-argument-based native-shadow
-- eligibility plus Compiler.RC2.DualABI's RLoopContinue native
-- promotion (rc2/doc/loop-conversion.md; see
-- Test57LoopCallArgNativeShadow.idr, which absorbed the former
-- Test58LoopContinueNativePromotion.idr):
-- a loop-carried accumulator threaded only through a helper call's own
-- native argument, and the helper's own native return fed straight
-- back into RLoopContinue, used to box/unbox on every iteration.
--
-- step's own body calls prim__labs (always 0, `+ prim__labs 0`) purely
-- so Compiler.RC2.Inline can't splice its tiny call-free arithmetic
-- straight into loop before Loop/DualABI ever see it -- without that
-- there'd be no RAppName call to step, and no RLet-bound call result,
-- for either fix to have anything to promote.

%foreign "C:labs,libc,stdlib.h"
prim__labs : Int -> Int

step : Int -> Int -> Int
step acc n = (acc * 2) + n + prim__labs 0

loop : Int -> Int -> Int
loop acc 0 = acc
loop acc n = loop (step acc n) (n - 1)

main : IO ()
main = printLn (loop 0 5000000)
