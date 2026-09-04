module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for the `RV _ (RCConstClosure {})` arm added to
-- Compiler.RC2.ConstFold's `RLet` value-classification (mirroring the
-- pre-existing `RCConstCon` arm right above it): a `let`-bound alias
-- of an already-folded closure constant (`let b = a`) must itself
-- re-enter `env` as the same constant, not just resolve `a`'s own
-- uses -- otherwise a later constructor built from `b` (rather than
-- `a` directly) never reaches the `RCConstCon` fold at all.
--
-- Getting a genuine, surviving `let b = a` (a plain local-to-local
-- alias) into rc2's own IR is the hard part: Idris2's own frontend
-- eagerly collapses that exact shape (confirmed by hand via
-- `--directive dumplifted` -- a plain `let a = greetFn; b = a in ...`
-- never even reaches `Compiler.LambdaLift`'s own output as two
-- bindings, regardless of which function it's written in). `mkAlias`
-- below is marked `%noinline` specifically to survive as a real call
-- in the *Lifted* IR (confirmed via `--dumplifted`: `Main.main`'s own
-- definition still shows `%let b = Main.mkAlias(!a) in ...`, a genuine
-- second binding) -- `Compiler.RC2.Inline` (rc2's own, separate,
-- Lifted-level inliner, which does not honour `%noinline` since that
-- flag is upstream's `Compiler.Inline` concept) then splices
-- `mkAlias`'s body (bare parameter passthrough) into the call site,
-- turning `b`'s own value into exactly `RV fc (RCLoc a)` before
-- ConstFold ever runs -- which folds through `env` into `RV fc
-- (RCConstClosure ...)`, landing precisely on the new arm.
--
-- Confirmed structurally: without the new arm, `dict`'s own
-- construction (`MkDict a b`) stays a genuine `RCon` -- the generated
-- `.c` has a real `idris2rc2_newConstructor(2, 1)` call inside
-- `Main_main`, with one field copied from a runtime local rather than
-- referencing the staged closure directly. With the arm, `dict` folds
-- into a single immortal `RCConstCon` (a `constcon_N` static whose two
-- fields both directly reference the *same* `constclosure_N` static)
-- and `Main_main` contains no constructor-allocating call at all.

greetFn : String -> String
greetFn s = "hello " ++ s ++ "!"

record Dict where
  constructor MkDict
  fnA : String -> String
  fnB : String -> String

useDict : Dict -> String -> String
useDict d s = fnA d s ++ " / " ++ fnB d s

%noinline
mkAlias : (String -> String) -> (String -> String)
mkAlias f = f

main : IO ()
main =
  let a = greetFn
      b = mkAlias a
      dict = MkDict a b
  in putStrLn (useDict dict "world")
