module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for Compiler.RC2.DupMerge's own branch-boundary
-- safety property: `s` is used three times in a row on the `True` arm
-- only, with an unrelated `False` arm that never even reads `s` (just
-- drops it). DupMerge must merge the `True` arm's own three uses of
-- `s` into one batched `RDup` WITHIN that arm alone -- collectDupCounts
-- is run separately per region (RConCase/RCmpCase/etc. alt bodies are
-- each their own fresh region, see DupMerge.idr's own module note), so
-- the `False` arm's own handling of `s` (an ordinary `RDrop`, since `s`
-- is unused there) must stay completely untouched: merging across the
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

main : IO ()
main = do
  maybeThrice True "left"
  maybeThrice False "left"
