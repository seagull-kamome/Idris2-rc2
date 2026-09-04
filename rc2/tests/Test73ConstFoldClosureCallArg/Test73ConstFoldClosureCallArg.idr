module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for `Compiler.RC2.ConstFold`'s `RCConstClosure`
-- folding (rc2/doc/const-closure-fold.md) when a zero-filled closure
-- flows into an ordinary CALL ARGUMENT position, not just a
-- constructor/dictionary field (Test69ConstFoldClosureDict's own
-- shape) -- this is the exact `map double [1,2,3,4,5]` shape
-- `TODO.md`'s former "Dropped: closure generation for statically-known
-- higher-order function arguments" entry was about. `useIt`'s own
-- `double` argument is confirmed (by hand, `--directive dumprcexpr` +
-- generated-C inspection) to fold into a single immortal
-- `constclosure_N` static baked directly into `useIt`'s own compiled
-- body -- called three times below from `main` with no
-- `idris2rc2_mkClosure` call for `double` appearing anywhere, proving
-- the closure is genuinely folded once at compile time, not rebuilt
-- per call.

double : Int -> Int
double x = x * 2

useIt : List Int -> List Int
useIt xs = map double xs

main : IO ()
main = do
  printLn (useIt [1,2,3])
  printLn (useIt [4,5,6])
  printLn (useIt [7,8,9])
