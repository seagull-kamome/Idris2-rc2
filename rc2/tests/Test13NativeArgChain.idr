module Main

import Data.Bits

-- Regression test for a gap in Compiler.RC2.Loop's `nativeArgTypes`
-- (shared by Compiler.RC2.DualABI's own worker-parameter eligibility):
-- `opNativeUsesThrough` only looked for a top-level parameter directly
-- inside the *value* of an `RNative`/`RInlineNative`-typed `RLet` --
-- when a multi-operation chain (ANF-normalized into nested `RLet`s)
-- put the parameter's own read in an *inner* let's `body` instead
-- (its own final operation), that read was invisible to the scan, so
-- the parameter stayed `RBoxed` regardless of how it was actually
-- used. `chain`'s own body below is exactly that shape: a two-
-- operation chain (`cast` then `xor`) mirroring a textbook hash-step
-- update. Fixed by having `opNativeUsesThrough` also recurse through a
-- nested `RLet`'s own `body`, still gated by the *outer* `RLet`'s
-- already-decided native `Rep` (unchanged: `flat` below, whose whole
-- body is a single, *unguarded* `ROp` with no enclosing `let` at all,
-- deliberately stays `RBoxed` -- an earlier, broader fix that treated
-- any bare `ROp` as native regardless of context caused a real,
-- `valgrind`-caught leak in Test9SelfTailLoop; see
-- rc2/doc/native-type-inference.md and TODO.md's git history for the
-- full investigation, which originally misattributed this gap to a
-- newtype-style constructor wrapper -- ruled out by reproducing with a
-- plain Bits64 parameter, no constructor involved at all).
--
-- Values are deliberately pushed well outside the small-int cache
-- range ([0,100), immortal) so a real heap allocation -- and a real
-- leak if this fix's own ownership-stripping ever regresses -- is
-- unavoidable; verify with:
--   valgrind --leak-check=full ./build/exec/<this test's own output>
-- and expect "definitely lost: 0 bytes in 0 blocks".

chain : Bits64 -> Bits8 -> Bits64
chain v b = (v `xor` cast b) * 0x100000001b3

-- Deliberately still RBoxed (see above) -- kept as a control so a
-- future change to this analysis that starts promoting it is a
-- visible prompt to re-check the Test9SelfTailLoop hazard, not a
-- silent behaviour change.
flat : Bits64 -> Bits64 -> Bits64
flat v k = v * k

loop : Bits64 -> List Bits8 -> Bits64
loop acc [] = acc
loop acc (b :: bs) = loop (chain acc b) bs

main : IO ()
main = do
    printLn (loop 0xcbf29ce484222325 [1,2,3,4,5,6,7,8,9,10])
    printLn (flat 0xdeadbeef00000001 0x100000001b3)
