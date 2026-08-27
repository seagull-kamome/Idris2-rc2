module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for Compiler.RC2.DualABI's Stage 3c (FFI worker
-- synthesis, `ffiWorkerTable`) with MORE than the old
-- `Compiler.RC2.EmitUtil.MaxExtractFunArgs` (20) parameters on a
-- `%foreign` declaration itself -- see TODO.md's "Scope: FFI worker
-- synthesis (Stage 3c) keeps its own 20-argument limit" (now resolved)
-- and `rc2/doc/dual-abi.md`'s "Stage 3c" for the full history. Mirrors
-- `Test33WideDualABIWorker.idr`'s own ordinary-function coverage, but
-- for a `%foreign` declaration: `prim__wide` below takes 15 parameters
-- (12 `Int`s, all native-eligible, + 3 `String`s, which stay `Boxed`),
-- past the old width limit that used to make `ffiEntry` return `[]`
-- unconditionally for any `%foreign` def this wide, regardless of how
-- many of its positions were genuinely native-eligible.
--
-- Called directly (fully saturated, non-tail position) from `main` so
-- Stage 4's call-site rewriting fires and the synthesized native
-- worker is actually reached, not just the always-Boxed wrapper.
%foreign "C:idris2rc2_test48_wide,libc,Test48WideFFIDualABIWorker.h"
prim__wide : Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int ->
             String -> String -> String -> Int

main : IO ()
main = do
  let r = prim__wide 1 2 3 4 5 6 7 8 9 10 11 12 "hello" "world" "!"
  putStrLn ("wide result: " ++ show r)
