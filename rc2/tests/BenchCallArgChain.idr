module Main

-- Measures Compiler.RC2.DualABI's call-argument promotion (rc2/doc/
-- dual-abi.md; see Test13NativeArgChain.idr, which absorbed the former
-- Test56NativeCallArgChain.idr): an RLet-bound worker call's result
-- that's consumed only as *another* worker's own native argument used
-- to box the intermediate value only to immediately unbox it again at
-- the callee's own entry. Same shape as Test13NativeArgChain.idr's
-- own former-Test56 half, hot-looped.
--
-- addAbs's own body calls prim__labs (not call-free), so
-- Compiler.RC2.Inline can't splice it into chain before DualABI ever
-- runs -- without that, there'd be no RAppName call site left for
-- this fix to have anything to promote.

%foreign "C:labs,libc,stdlib.h"
prim__labs : Int -> Int

addAbs : Int -> Int -> Int
addAbs x y = (x + prim__labs y) * 2

chain : Int -> Int -> Int
chain x y = addAbs (prim__labs x) y + 1

loop : Int -> Int -> Int
loop 0 acc = acc
loop n acc = loop (n - 1) (acc + chain (n - 2500000) 3)

main : IO ()
main = printLn (loop 5000000 0)
