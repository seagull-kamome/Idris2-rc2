module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression/smoke test for Compiler.RC2.DualABI's Stage 5
-- (`inlineFFIWorkers` -- see rc2/doc/dual-abi.md's "Stage 3c"/"Stage
-- 5" sections): a direct, saturated, non-tail-position call to a
-- native-representation-eligible `%foreign` declaration is compiled
-- straight to an `RAppFFIInline` node, splicing the marshalling logic
-- a standalone `idris2rc2_ffiworker_*` C function used to carry
-- directly at the call site instead -- no such worker function is
-- generated at all any more. Mirrors Test27FFIDualABI.idr's own
-- signature coverage (all-native, mixed native+Boxed, a CFChar
-- narrow/widen round trip, a CFUnit IO return) so the same set of
-- CFType shapes is exercised under the new design, but with its own
-- distinct C symbols so both tests can build/link independently.
--
-- `loop` deliberately builds the FFI argument via native arithmetic
-- directly inside its own self-tail-call operand position, same
-- reasoning as Test27FFIDualABI.idr's own `loop`: by the time
-- Compiler.RC2.Loop has turned this into a native-`int64_t` loop, the
-- `prim__add50` call sits in a genuinely non-tail position (an operand
-- of `+`) with both arguments already native on arrival -- exactly the
-- shape that used to redirect to a synthesized FFI worker (Stage 4)
-- and now inlines directly (Stage 5) instead. This also exercises the
-- interaction between Stage 4's own `RLet` native-return promotion
-- (`applyCallSiteRewriteBody`'s `promotedTy`, unmodified by this
-- change) and the later node-swap: `v3 + v5`-style native accumulation
-- must keep skipping the box-then-immediately-unbox round trip even
-- though the call itself is no longer `RAppNameRep` into a worker by
-- the time Emit.idr ever sees it.
--
-- Values pushed well outside the small-int cache range ([0,100),
-- immortal) so a real heap allocation -- and a real leak/double-free if
-- the Boxed-argument-ownership handling `emitAppFFIInlineInto` now
-- does itself (previously done inside the deleted worker's own C
-- body) ever regresses -- is unavoidable. `prim__mixed50`'s own
-- `String` argument is the position most likely to expose a
-- regression here (the genuinely-Boxed argument position
-- `Compiler.RC2.Emit`'s `ffiRawCall` must unconditionally drop after
-- the call, independent of any `postDrop` entry). Verify with:
--   valgrind --leak-check=full ./build/exec/<this test's own output>
-- and expect "definitely lost: 0 bytes in 0 blocks".

%foreign "C:idris2rc2_test50_add,libc,Test50FFIInlineNoWorker.h"
prim__add50 : Int -> Int -> Int

%foreign "C:idris2rc2_test50_mixed,libc,Test50FFIInlineNoWorker.h"
prim__mixed50 : Int -> String -> Int

%foreign "C:idris2rc2_test50_noop,libc,Test50FFIInlineNoWorker.h"
prim__noop50 : Int -> PrimIO ()

%foreign "C:idris2rc2_test50_bumpChar,libc,Test50FFIInlineNoWorker.h"
prim__bumpChar50 : Char -> Char

loop : Int -> Int -> Int
loop 0 acc = acc
loop n acc = loop (n - 1) (acc + prim__add50 (n + 999999) (n + 1000001))

main : IO ()
main = do
    printLn (prim__add50 3 4)
    printLn (loop 200000 0)
    printLn (prim__mixed50 10 "hello")
    primIO (prim__noop50 5)
    printLn (ord (prim__bumpChar50 (chr 254)))
    putStrLn "done"
