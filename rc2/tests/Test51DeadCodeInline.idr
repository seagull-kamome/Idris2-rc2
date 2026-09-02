module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for Compiler.RC2.DeadCode: `addTen` is small,
-- call-free, and called from exactly one place, so Compiler.RC2.Inline
-- splices its body directly into `main` (see rc2/doc/inlining.md's own
-- eligibility rules), leaving `addTen`'s own top-level definition with
-- zero remaining callers anywhere in the final program. `n` is bound
-- through a `let` rather than passed as a bare literal specifically to
-- avoid Inline's own `allLiteralArgs` guard (see that module's own
-- doc), which would otherwise skip inlining this call entirely.
--
-- `addTen`'s own now-orphaned definition doesn't just sit there as one
-- inert `MkRCFun`, either: nothing downstream of Inline knows it has
-- become dead, so `Compiler.RC2.DualABI`'s Stage 3a still splits it
-- into its own (equally uncalled) wrapper+worker pair. Confirmed by
-- hand (see rc2/doc/dead-code-elim.md): `--directive dumprcexpr` shows
-- neither `Main.addTen` nor its worker at all with this pass enabled,
-- vs. both present (and genuinely uncalled) with `--directive
-- nodeadcode`.

addTen : Int -> Int
addTen x = x + 10

main : IO ()
main = do
    let n = cast (String.length "hello")
    printLn (addTen n)
