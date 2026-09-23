module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Merged regression suite for Compiler.RC2.DupMerge -- three formerly
-- separate tests, one per structural property the pass has to get
-- right. Each section below keeps its own original doc comment
-- verbatim; `main` runs all three in order and the saved .expected is
-- their concatenation.
--
--   * straight-line  (was Test79DupMergeStraightLine)
--   * branch boundary (was Test80DupMergeBranchBoundary)
--   * RLet scope      (was Test81DupMergeLetScope)
--   * dup/drop cancellation (`cancelDupDrop`)

import Data.List
import System

-- ============================================================
-- Section 1: straight-line region (was Test79DupMergeStraightLine)
-- ============================================================
-- `s` is used three times in a row inside one straight-line region (no
-- intervening branch/loop) -- two borrows (the first two `putStrLn`
-- calls) plus one final move (the last `putStrLn` call). `annotate`
-- (Phase 2) would otherwise insert two individual `RDup s 0` nodes
-- ahead of the first two calls; DupMerge should collapse both into a
-- single `RDup s 1` (i.e. one `idris2rc2_dup_n(v, 2)` call,
-- incrementing by 2 in one shot) ahead of the first use, with the
-- second occurrence spliced out entirely.
--
-- Confirmed by hand via `--directive dumprcexpr`: the dump shows one
-- `RDup` for `s` with `extra=1` (not two separate `RDup ... 0` nodes),
-- and the generated `.c` has exactly one `idris2rc2_dup_n(v..., 2)`
-- call for the local holding `s`, no separate `idris2rc2_dup` calls for
-- it at all.

useThrice : String -> IO ()
useThrice s = do
  putStrLn s
  putStrLn s
  putStrLn s

-- ============================================================
-- Section 2: branch-boundary safety (was Test80DupMergeBranchBoundary)
-- ============================================================
-- `s` is used three times in a row on the `True` arm only, with an
-- unrelated `False` arm that never even reads `s` (just drops it).
-- DupMerge must merge the `True` arm's own three uses of `s` into one
-- batched `RDup` WITHIN that arm alone -- collectDupCounts is run
-- separately per region (RConCase/RCmpCase/etc. alt bodies are each
-- their own fresh region, see DupMerge.idr's own module note), so the
-- `False` arm's own handling of `s` (an ordinary `RDrop`, since `s` is
-- unused there) must stay completely untouched: merging across the
-- branch would over-count `s`'s refcount on whichever arm is NOT taken
-- at runtime, a permanent leak.
--
-- Confirmed by hand via `--directive dumprcexpr`: the `True` alt's own
-- three uses of `s` collapse into one `RDup s 1` inside that alt only;
-- the `False` alt still shows its own plain `RDrop [s, ...]`, entirely
-- unaffected by the other alt's own count.

maybeThrice : Bool -> String -> IO ()
maybeThrice b s =
  if b
     then do putStrLn s; putStrLn s; putStrLn s
     else putStrLn "no"

-- ============================================================
-- Section 3: RLet-scope safety (was Test81DupMergeLetScope)
-- ============================================================
-- `s` is bound by its own `let` (inside a `do`-block, guarded by a
-- runtime-only condition so `Compiler.RC2.ConstFold`/normalize can't
-- fold the whole `let` away into a bare string literal the way a plain
-- `let s = "literal"` would -- `getArgs`'s own result is only known at
-- runtime, so the `if` deciding `s`'s value can't be constant-folded,
-- keeping `s` a genuine RLet-bound `RCLoc` all the way through this
-- pipeline) and then used three times in a row. Since `s`'s own
-- newly-bound variable can never be referenced inside its own `RLet`'s
-- `value` (it doesn't exist yet at that point -- see DupMerge.idr's own
-- module note and RCExp.idr's `RLet`), every `RDup` targeting it can
-- only ever appear inside `body`, so merging must never hoist the
-- merged dup earlier than `s`'s own binding site.
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

letThrice : IO ()
letThrice = do
  args <- getArgs
  let s = if length args > 100 then "unreachable" else "let-bound"
  putStrLn s
  putStrLn s
  putStrLn s

-- ============================================================
-- Section 4: dup/drop cancellation (DupMerge's own cancelDupDrop)
-- ============================================================
-- A `where`-bound helper is lifted with EVERY one of its parent's own
-- arguments as its own parameters, whether or not it reads them.
-- `prefixPart` ignores `x` entirely, so once the helper is inlined back
-- into its single caller the inlined body opens with the caller's own
-- `RDup x` (the call protocol's borrow for an argument the caller still
-- owns) immediately followed by the callee's own `RDrop [x]` (it never
-- reads it): two atomic RMWs on the same counter with nothing in
-- between that could observe it. `cancelDupDrop` removes both.
--
-- This is the exact shape idris2-lsp's own
-- `Compiler.Opts.Constructor.mkIntrinsicName` produces -- its
-- `where`-bound `intrinsicNS = mkNamespace "_builtin"` ignores its
-- parent's `x` the same way. 1,539 such increment/decrement pairs came
-- out of a whole idris2-lsp build.
--
-- The `case Just ... of` keeps `prefixPart`'s own result from folding
-- straight into the `++`, and `getArgs` keeps the branch runtime-only,
-- the same trick Section 3 uses (`getArgs` counts the program name
-- itself, so the threshold is a plain "far more arguments than anyone
-- passes", not zero). A normal invocation always yields "zero",
-- deterministic across runs.
--
-- Confirmed by hand via `--directive dumprcexpr`: under
-- `--directive nodupmerge` the dump shows `dup v<x>` directly followed
-- by `drop [v<x>]` ahead of the inlined `prefixPart` body; without it
-- both are gone. verify.sh re-checks that absence on every run (see its
-- own Test79DupMerge case) -- nothing else in the suite exercises this
-- peephole at all, so without that check it could stop firing entirely
-- and every test would still pass.

%noinline
mkTag : String -> String
mkTag x = case Just prefixPart of
               Nothing => "u:" ++ x
               Just p  => p ++ "/" ++ x
  where
    prefixPart : String
    prefixPart = pack (reverse (unpack "nitliub_"))

tagOnce : IO ()
tagOnce = do
  args <- getArgs
  putStrLn (mkTag (if length args > 100 then "unreachable" else "zero"))

main : IO ()
main = do
  useThrice "dup-merge"
  maybeThrice True "left"
  maybeThrice False "left"
  letThrice
  tagOnce
