module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for Compiler.RC2.DupMerge's own RLet-scope-safety
-- property: `s` is bound by its own `let` (inside a `do`-block, guarded
-- by a runtime-only condition so `Compiler.RC2.ConstFold`/normalize
-- can't fold the whole `let` away into a bare string literal the way a
-- plain `let s = "literal"` would -- `getArgs`'s own result is only
-- known at runtime, so the `if` deciding `s`'s value can't be
-- constant-folded, keeping `s` a genuine RLet-bound `RCLoc` all the way
-- through this pipeline) and then used three times in a row. Since
-- `s`'s own newly-bound variable can never be referenced inside its own
-- `RLet`'s `value` (it doesn't exist yet at that point -- see
-- DupMerge.idr's own module note and RCExp.idr's `RLet`), every `RDup`
-- targeting it can only ever appear inside `body`, so merging must
-- never hoist the merged dup earlier than `s`'s own binding site.
--
-- Confirmed by hand via `--directive dumprcexpr`: the merged `RDup s`
-- appears strictly AFTER the `RLet` that binds `s` to its own value,
-- never before it (in fact, given `RLet`'s value/body split into
-- separate C statements, the merged dup can only ever land inside the
-- `body` half in the first place -- exactly the safety property this
-- test regression-checks).
--
-- A normal invocation (no extra command-line arguments) always takes
-- the `else` branch, so `s` is always "let-bound" here, deterministic
-- across runs.

import System

letThrice : IO ()
letThrice = do
  args <- getArgs
  let s = if length args > 100 then "unreachable" else "let-bound"
  putStrLn s
  putStrLn s
  putStrLn s

main : IO ()
main = letThrice
