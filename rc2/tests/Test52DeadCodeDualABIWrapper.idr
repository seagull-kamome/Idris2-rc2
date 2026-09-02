module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for Compiler.RC2.DeadCode: `helper` has a native-
-- eligible (`Int`) argument and return, so Compiler.RC2.DualABI's
-- Stage 3a synthesizes it an always-Boxed wrapper plus a native-
-- calling-convention worker. `helper`'s own one and only call site
-- (`helper 5 + 0`, a non-tail-position operand of `+`) gets rewritten
-- by Stage 4 to call the worker directly (see rc2/doc/dual-abi.md) --
-- `helper`'s own wrapper is therefore never called by anything;
-- `main` reaches the worker straight through the rewritten call site.
--
-- `helper` calls `addOne` three times so its own body isn't call-free
-- (ineligible for Compiler.RC2.Inline, unlike Test51DeadCodeInline.idr's
-- `addTen`) and therefore still exists as a genuine function by the
-- time DualABI runs. `addOne` itself IS Inline-eligible (call-free,
-- small, inlined at all three of its own call sites) and becomes a
-- second, independent instance of the same dead-original-definition
-- situation Test51DeadCodeInline.idr covers on its own -- not this
-- test's own point, but not wrong to also observe here.
--
-- Confirmed by hand (see rc2/doc/dead-code-elim.md): `helper`'s own
-- wrapper C function is absent from the generated `.c` with this pass
-- enabled (only its worker remains, called directly from `main`),
-- present (but genuinely uncalled) with `--directive nodeadcode`.

addOne : Int -> Int
addOne x = x + 1

helper : Int -> Int
helper x = addOne (addOne (addOne x))

main : IO ()
main = printLn (helper 5 + 0)
