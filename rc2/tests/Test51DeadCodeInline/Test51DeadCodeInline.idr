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
--
-- Also covers the DualABI-wrapper-shaped side of the same dead-code
-- gap (formerly a separate Test52DeadCodeDualABIWrapper.idr, merged in
-- below as `addOne`/`helper`): `helper` has a native-eligible (`Int`)
-- argument and return, so Compiler.RC2.DualABI's Stage 3a synthesizes
-- it an always-Boxed wrapper plus a native-calling-convention worker.
-- `helper`'s own one and only call site (`helper 5 + 0`, a non-tail-
-- position operand of `+`) gets rewritten by Stage 4 to call the
-- worker directly (see rc2/doc/dual-abi.md) -- `helper`'s own wrapper
-- is therefore never called by anything; `main` reaches the worker
-- straight through the rewritten call site. `helper` calls `addOne`
-- three times so its own body isn't call-free (ineligible for
-- Compiler.RC2.Inline, unlike `addTen` above) and therefore still
-- exists as a genuine function by the time DualABI runs. `addOne`
-- itself IS Inline-eligible (call-free, small, inlined at all three of
-- its own call sites) and becomes a second, independent instance of
-- the same dead-original-definition situation `addTen` covers above --
-- not this half's own point, but not wrong to also observe here.
-- Confirmed by hand (see rc2/doc/dead-code-elim.md): `helper`'s own
-- wrapper C function is absent from the generated `.c` with this pass
-- enabled (only its worker remains, called directly from `main`),
-- present (but genuinely uncalled) with `--directive nodeadcode`.

addTen : Int -> Int
addTen x = x + 10

addOne : Int -> Int
addOne x = x + 1

helper : Int -> Int
helper x = addOne (addOne (addOne x))

main : IO ()
main = do
    let n = cast (String.length "hello")
    printLn (addTen n)
    -- absorbed from former Test52DeadCodeDualABIWrapper
    printLn (helper 5 + 0)
