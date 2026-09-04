module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for Compiler.RC2.DupMerge: `s` is used three times
-- in a row inside one straight-line region (no intervening branch/
-- loop) -- two borrows (the first two `putStrLn` calls) plus one final
-- move (the last `putStrLn` call). `annotate` (Phase 2) would otherwise
-- insert two individual `RDup s 0` nodes ahead of the first two calls;
-- DupMerge should collapse both into a single `RDup s 1` (i.e. one
-- `idris2rc2_dup_n(v, 2)` call, incrementing by 2 in one shot) ahead of
-- the first use, with the second occurrence spliced out entirely.
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

main : IO ()
main = useThrice "dup-merge"
