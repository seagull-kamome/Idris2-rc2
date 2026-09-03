module Main

-- Regression test for a real reference leak found in
-- `Compiler.RC2.RCExp`'s own `RLoopContinue` (the self-tail-loop
-- continuation node `Compiler.RC2.Loop`'s `applyLoop` produces): unlike
-- every other RCExp construct that reads a `Boxed` value *natively*
-- (`ROp`/`RCmpCase`/`RAppNameRep`, each carrying an explicit `postDrop`
-- field), `RLoopContinue` had no such field at all, so a native-shadowed
-- loop parameter fed by a still-`Boxed` continuation argument got read
-- natively (`Compiler.RC2.Emit`'s `rcVarToNativeC`) to build the next
-- iteration's own native temp, but its own Boxed source was never
-- dropped.
--
-- `loop`'s own accumulator gets native-shadowed because it's read as a
-- *chained* arithmetic operand (`(acc * 3) + 1` -- deliberately two
-- operations, not one: `Compiler.RC2.RC`'s own ANF normalisation only
-- ever `RLet`-binds a chain's own *intermediate* steps as `Native`, and
-- leaves a lone, single-operation branch's own result as a *bare* tail
-- value instead, which `Compiler.RC2.Loop`'s own `nativeArgTypes`
-- deliberately does not treat as a native-context use at all --
-- confirmed by direct experiment: `if acc == 0 then acc * 2 else acc +
-- 1` alone, with each branch a single bare op, never native-shadows
-- `acc` here, matching `nativeArgTypes`'s own documented, deliberate
-- conservatism, see its own doc comment in `Compiler.RC2.Loop` for why
-- guessing at a bare op's own context caused a real leak the one time
-- it was tried). `Compiler.RC2.Loop`'s own `nativeArgTypes` finds `acc`
-- via the *chain's* own inner `let`, regardless of how the `if`'s own
-- *condition* is computed -- confirmed via `--directive dumprcexp` that
-- the condition itself (`acc == 0`, `Int`'s `Eq` instance) stays an
-- ordinary, unfused call through `Prelude.EqOrd.==`'s own Dual-ABI
-- worker here (interface-dispatched comparisons don't fuse into
-- `RCmpCase` on their own at all -- a separate, unrelated gap),
-- irrelevant to this bug, which only cares that the `if`'s own *result*
-- feeding the recursive call is a `case`-valued `RLet`.
-- `Compiler.RC2.Types.repOf` never promotes a `case`'s own let-binding
-- to `Native` on its own (it only promotes a direct `ROp`/`RPrimVal`,
-- even when every one of the case's own branches is itself
-- native-eligible) -- so that value stays `Boxed`, and needs exactly
-- the native-read-then-drop treatment `RLoopContinue`'s own new
-- `postDrop` field now provides. This exact shape is the real, general,
-- entirely pre-existing bug -- nothing here depends on
-- `Compiler.RC2.Inline` at all, and it's the same shape
-- `Test9SelfTailLoop.idr`'s own `collatzLike` was already hitting via
-- its own `(acc * 3) + 1` chain (its own long-`KNOWN-BUGS.md`-
-- documented 784-byte leak, now also fixed by this same change).
--
-- `acc` starts well outside the small-int cache range ([0,100),
-- immortal) and only grows from there, so the leaking branch's own
-- fresh allocation is real and `valgrind`-visible on almost every
-- iteration; verify with:
--   valgrind --leak-check=full ./build/exec/<this test's own output>
-- and expect "definitely lost: 0 bytes in 0 blocks".
--
-- This test actually exercises *two* independent, pre-existing leaks
-- that happen to both live on this exact shape (fixing only one leaves
-- the leak count roughly halved, not clean): the `RLoopContinue`
-- `postDrop` gap described above (`var_3`, the `if`'s own Boxed result,
-- read natively into the loop's native shadow and never dropped), and a
-- second, unrelated one in `Compiler.RC2.Emit`'s `ROp` case: inside the
-- `if`'s own `else` branch, `(acc * 3) + 1` is itself a plain native
-- `Int64` computation, but the enclosing `RLet`'s own Rep stays `RBoxed`
-- (`Types.repOf` never promotes a `case`/`if`-valued `RLet` to Native,
-- per the same reasoning as above) -- so `Emit.idr` has to box that
-- native `Add` op's own *operand* on the fly (`idris2rc2_mkInt64`) just
-- to call the Boxed `idris2rc2_add_Int64` primitive, and that ephemeral,
-- unnamed box was never freed either. See `Compiler.RC2.Emit`'s
-- `boxOpArg` for the fix (names the fresh box so it can be dropped once
-- the op is done reading it, mirroring how `RLoopContinue`'s own
-- `postDrop` treats a natively-read Boxed value).

loop : Nat -> Int -> Int
loop Z acc = acc
loop (S k) acc = loop k (if acc == 0 then acc else (acc * 3) + 1)

main : IO ()
main = printLn (loop 1000000 0x7eadbeef)
