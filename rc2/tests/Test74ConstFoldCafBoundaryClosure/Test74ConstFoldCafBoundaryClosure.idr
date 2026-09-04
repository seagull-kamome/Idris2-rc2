module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for Compiler.RC2.ConstFold's whole-program CAF fold
-- (RC2.idr's own `foldConstProgram`): `dict` is a closure-shaped CAF
-- (a record whose every field is a zero-filled closure, same shape as
-- Test69ConstFoldClosureDict's own interface dictionary) referenced
-- from a SEPARATE definition (`useDict`), not built inline inside
-- `main` -- crossing exactly the call boundary Compiler.RC2.Inline's
-- own `isCallFree (LUnderApp {}) = False` unconditionally refuses to
-- cross (see ConstFold.idr's own `CafTable` doc comment). If this
-- folds correctly, it's proof the new whole-program `CafTable`, not
-- `Inline`, is what did it.
--
-- Confirmed by hand via `--directive dumprcexpr`: `Main.useDict`'s own
-- dump references the folded `Main.dict` dictionary directly as a
-- `RCConstCon`/`RCConstClosure` literal, never a `RAppName ... "Main.
-- dict" []` call.

record Pair where
  constructor MkPair
  fn1 : Int -> Int
  fn2 : Int -> Int

op1 : Int -> Int
op1 x = x + 1

op2 : Int -> Int
op2 x = x * 2

dict : Pair
dict = MkPair op1 op2

useDict : Pair -> Int -> Int
useDict p x = p.fn2 (p.fn1 x)

main : IO ()
main = printLn (useDict dict 10)
