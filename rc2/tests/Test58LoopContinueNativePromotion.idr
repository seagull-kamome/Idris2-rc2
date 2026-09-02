module Main

%foreign "C:labs,libc,stdlib.h"
prim__labs : Int -> Int

-- Regression test for Compiler.RC2.DualABI's own `nativePromotionFor`
-- recognizing an `RLoopContinue` argument position as a native context
-- (closes rc2/doc/loop-conversion.md's former "Known limitation"
-- section's remaining, "return side" gap -- the argument-feeding side
-- was already closed by Test57LoopCallArgNativeShadow.idr).
--
-- Reuses that test's own step/loop shape verbatim: `loop`'s own call
-- `loop (step acc n) ns` ANF-normalizes to `let v = step acc n in
-- RLoopContinue [v, ns] postDrop` -- a call used as another call's own
-- argument is always let-bound by this compiler's ANF, no further
-- coaxing needed. `acc`'s own loop-carried parameter already gets a
-- native shadow via Test57's own fix (`step`'s own parameter reads it
-- as a chained arithmetic operand); `step`'s own call result `v` is
-- independently native-*return*-eligible too (its own body is a bare
-- native arithmetic tail) -- but until this fix, nothing recognised
-- "fed straight into RLoopContinue at that already-native slot" as a
-- promotion-worthy context, so `v` stayed Boxed: `step`'s native
-- worker return got boxed only to be immediately unboxed again for the
-- next iteration's own native shadow.
--
-- Same anti-splicing trick as Test57's own `step` (`+ prim__labs 0`):
-- without it, Compiler.RC2.Inline would splice step's tiny, entirely
-- call-free arithmetic body directly into loop before MutualLoop/Loop/
-- DualABI ever run, leaving no RAppName call -- and so no RLet-bound
-- call result at all -- for this fix to have anything to promote.
--
-- Values pushed well outside the small-int cache range ([0,100),
-- immortal) so a real heap allocation -- and a real leak if the
-- ownership bookkeeping this fix relies on ever regresses -- is
-- unavoidable; verify with:
--   valgrind --leak-check=full ./build/exec/Test58LoopContinueNativePromotion
-- and expect "definitely lost: 0 bytes in 0 blocks".
step : Int -> Int -> Int
step acc n = (acc * 2) + n + prim__labs 0

loop : Int -> List Int -> Int
loop acc [] = acc
loop acc (n :: ns) = loop (step acc n) ns

main : IO ()
main = printLn (loop 987654321 [11,22,33,44,55,66,77,88,99,100])
