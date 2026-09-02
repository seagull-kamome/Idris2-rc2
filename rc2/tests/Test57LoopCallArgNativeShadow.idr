module Main

%foreign "C:labs,libc,stdlib.h"
prim__labs : Int -> Int

-- Regression test for Compiler.RC2.Loop's call-argument-based native-
-- shadow eligibility (closes rc2/doc/loop-conversion.md's "Known
-- limitation" gap): a loop-carried parameter passed only as an
-- argument to a plain (non-FFI) helper now gets a native shadow too,
-- once the helper's own corresponding parameter is independently
-- native-eligible by Compiler.RC2.Loop's own (unchanged)
-- `nativeArgType`.
--
-- `step`'s own body is deliberately `(acc * 2) + n`, not
-- `acc + n * 2`: ordinary precedence would put `acc` directly as the
-- outermost, un-let-bound tail operation's own operand -- the same
-- bare-tail shape Test13NativeArgChain.idr's own `flat` deliberately
-- keeps Boxed -- which `nativeArgType` correctly declines regardless
-- of this fix. Grouping `acc * 2` first puts `acc`'s own read inside a
-- nested, native-Rep'd `let` instead, the shape `nativeArgType`
-- already recognises (mirrors Test13NativeArgChain.idr's own `chain`
-- and Test56NativeCallArgChain.idr's own `addAbs`).
--
-- The trailing `+ prim__labs 0` (always 0 -- `labs(0) == 0`, so it
-- never changes the printed result) is NOT part of the accumulator
-- arithmetic this test is actually about -- it exists purely so
-- `step`'s own body calls an FFI-declared function, making
-- `Compiler.RC2.Inline`'s `isCallFree` check on `step`'s body False.
-- Without it, `step`'s tiny, entirely call-free arithmetic body would
-- be spliced directly into `loop` by the Inline pass (which runs
-- before Compiler.RC2.MutualLoop/Loop even see the program) well
-- before Loop conversion ever runs -- leaving no `RAppName` call to
-- `step` for `buildCalleeTable`/`callArgNativeTypes` to find at all,
-- and defeating the entire point of this regression test (silently
-- passing on `nativeArgType` alone, unable to tell the fix apart from
-- its absence). Same trick as Test56NativeCallArgChain.idr's own
-- `addAbs`, which calls `prim__labs` for exactly this reason.
--
-- Values pushed well outside the small-int cache range ([0,100),
-- immortal) so a real heap allocation -- and a real leak if the
-- ownership bookkeeping this fix relies on ever regresses -- is
-- unavoidable; verify with:
--   valgrind --leak-check=full ./build/exec/Test57LoopCallArgNativeShadow
-- and expect "definitely lost: 0 bytes in 0 blocks".
step : Int -> Int -> Int
step acc n = (acc * 2) + n + prim__labs 0

loop : Int -> List Int -> Int
loop acc [] = acc
loop acc (n :: ns) = loop (step acc n) ns

main : IO ()
main = printLn (loop 123456789 [1,2,3,4,5,6,7,8,9,10])
