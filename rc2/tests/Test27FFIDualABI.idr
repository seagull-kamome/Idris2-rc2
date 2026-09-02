module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression/smoke test for the dual-ABI FFI worker
-- (Compiler.RC2.DualABI's ffiWorkerTable, Compiler.RC2.Emit's
-- emitFFIWorker -- see rc2/doc/dual-abi.md's "Stage 3c"): a %foreign
-- declaration's own primitive-typed arguments/return no longer force
-- a box-then-immediately-unbox round trip at every call site once a
-- native worker exists alongside the always-Boxed wrapper. Covers
-- every CFType shape that distinguishes an eligible position from an
-- ineligible one: Int/Int32/Bits64/Double (all-native), a mixed Int+String
-- signature (only the Int position promotes), an Int arg with a
-- CFUnit IO return (return stays Boxed, the arg still promotes), and a
-- CFChar arg/return round trip -- the one native-eligible CFType whose
-- own worker-boundary C type (uint32_t) disagrees with its %foreign
-- call-site C type (char), so it needs an explicit cast rather than a
-- verbatim pass-through (Compiler.RC2.Emit's nativeCharArgExpr/
-- nativeCharRetExpr). Uses codepoint 254 -> bumped to 255, both past
-- plain char's signed range on a typical platform, to catch a
-- regression that sign-extends the return instead of zero-extending
-- it (255 misread as 4294967295).
--
-- `loop` deliberately builds the FFI argument via native arithmetic
-- (`n + 999999`, `n + 1000001`) directly inside its own self-tail-call
-- operand position -- `Compiler.RC2.Loop`'s own goto conversion has
-- already turned `loop` into a native-`int64_t` loop by the time
-- Dual ABI's Stage 4 runs, so this `prim__add` call sits in a genuinely
-- non-tail position (an operand of `+`, not the loop's own
-- continuation target) with both arguments already native on arrival
-- -- exactly the box-then-immediately-unbox round trip this whole
-- feature exists to skip (a separate top-level helper function's own
-- body doesn't work for this: that would make the `prim__add` call
-- *that helper's own* tail position, which Stage 4 deliberately never
-- rewrites -- see rc2/doc/dual-abi.md's own tail-position scope
-- boundary). Values pushed well outside the small-int cache range
-- ([0,100), immortal) so a real heap allocation -- and a real leak if
-- worker/wrapper ownership handling ever regresses -- is unavoidable;
-- verify with:
--   valgrind --leak-check=full ./build/exec/<this test's own output>
-- and expect "definitely lost: 0 bytes in 0 blocks".

%foreign "C:idris2rc2_test27_add,libc,Test27FFIDualABI.h"
prim__add : Int -> Int -> Int

%foreign "C:idris2rc2_test27_scaleBits64,libc,Test27FFIDualABI.h"
prim__scaleBits64 : Bits64 -> Bits64 -> Bits64

%foreign "C:idris2rc2_test27_scaleInt32,libc,Test27FFIDualABI.h"
prim__scaleInt32 : Int32 -> Int32 -> Int32

%foreign "C:idris2rc2_test27_mulDouble,libc,Test27FFIDualABI.h"
prim__mulDouble : Double -> Double -> Double

%foreign "C:idris2rc2_test27_mixed,libc,Test27FFIDualABI.h"
prim__mixed : Int -> String -> Int

%foreign "C:idris2rc2_test27_noop,libc,Test27FFIDualABI.h"
prim__noop : Int -> PrimIO ()

%foreign "C:idris2rc2_test27_bumpChar,libc,Test27FFIDualABI.h"
prim__bumpChar : Char -> Char

loop : Int -> Int -> Int
loop 0 acc = acc
loop n acc = loop (n - 1) (acc + prim__add (n + 999999) (n + 1000001))

main : IO ()
main = do
    printLn (prim__add 3 4)
    printLn (loop 200000 0)
    printLn (prim__scaleBits64 6 7)
    printLn (prim__scaleInt32 (-6) 7)
    printLn (prim__mulDouble 2.5 4.0)
    printLn (prim__mixed 10 "hello")
    primIO (prim__noop 5)
    printLn (ord (prim__bumpChar (chr 254)))
    putStrLn "done"
