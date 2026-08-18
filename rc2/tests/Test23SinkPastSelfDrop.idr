module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for a real miscompile found while building
-- Compiler.RC2.Sink's "peel through an unrelated RLet" extension
-- (see rc2/doc/branch-sinking.md's own "Sinking past an unrelated
-- let"/"Not peeling through var's own death" sections): a chain of
-- `do`-notation IO actions whose own `()` result is immediately
-- discarded lowers to `let v5 = call sideEffect [..] in drop [v5]; let
-- v6 = call sideEffect [..] in drop [v6]; ...` -- each one wrapped by
-- exactly one `RDrop [vN]` that's *its own* death, not an unrelated
-- ownership wrapper to see past. Before this fix, `trySinkInto`'s old
-- unconditional "peel through any RDrop" clause treated that as just
-- another wrapper, and kept searching straight through the whole
-- chain to a distant, unrelated branch -- producing a real miscompile
-- (`refc-suite/buffer`'s own `TestBuffer.idr`, which has exactly this
-- do-notation shape via `setByte`/`setBits8`/`setBits16`/...,
-- generated C referencing `var_5`/`var_6`/... without ever declaring
-- them). This test reproduces the same shape directly, independent of
-- Data.Buffer, so it stays a dedicated rc2/tests/ regression rather
-- than relying on refc-suite alone catching it again.
sideEffect : Int -> IO ()
sideEffect n = pure ()

chainThenBranch : Bool -> Int -> Int -> IO Int
chainThenBranch flag a b = do
  sideEffect a
  sideEffect b
  sideEffect a
  sideEffect b
  pure (if flag then a else b)

main : IO ()
main = do
  r1 <- chainThenBranch True 3 4
  printLn r1
  r2 <- chainThenBranch False 3 4
  printLn r2
