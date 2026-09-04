module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for Compiler.RC2.ConstFold's new RCConstClosure fold
-- (RCExp.idr's own doc comment): a literal, zero-args `RUnderApp` --
-- a bare reference to a named top-level function, no captured values
-- -- folds into a constant leaf the same way `RCConstCon` already
-- folded a fully-constant constructor. `Greeter Dog`'s own instance
-- dictionary is exactly the shape this exists for: a 3-field record
-- whose every field is a zero-filled closure over one of the three
-- method implementations below (`greet_Dog`/`loud_Dog`/`cnt_Dog`,
-- Idris2's own generated names) -- since `isConstLocalProof` now
-- recognises each of those as `RCConstClosure`, ConstFold's existing
-- `RCon`-folding logic (unmodified -- see ConstFold.idr's own module
-- note) folds the *whole* dictionary into a single immortal
-- `RCConstCon`, with no code of its own having to know anything about
-- interfaces specifically.
--
-- Confirmed by hand via `--directive dumprcexpr` (same convention as
-- Test51DeadCodeInline): `Main.main`'s own dump shows the dictionary
-- passed to `Main.useGreeter` as a single folded literal --
-- `#Main.Greeter@Just 0([#Main.{main:0}/1~closure,
-- #Main.{main:1}/1~closure, #Main.{main:2}/1~closure])` -- never a
-- `RCon`/`RUnderApp` chain. The generated `.c` confirms this isn't
-- just a pretty-printer artifact: `Main_main`'s own C function body has
-- no `idris2rc2_mkClosure(` call anywhere building the dictionary or
-- any of its three fields, only three `constclosure_N` file-scope
-- statics (one `IDRIS2RC2_STOCKVAL(IDRIS2RC2_TAG_CLOSURE)`-tagged
-- struct per method, `fn` pointing directly at the mangled method
-- name) referenced from a single `constcon_N` static (the dictionary
-- itself, `IDRIS2RC2_STOCKVAL(IDRIS2RC2_TAG_CONSTRUCTOR)`-tagged) --
-- both staged once, at file scope, and simply addressed by
-- `Main_main`, never rebuilt.

interface Greeter a where
  greet : a -> String
  loud : a -> String
  cnt : a -> Int

data Dog = MkDog

Greeter Dog where
  greet MkDog = "woof"
  loud MkDog = "WOOF!!"
  cnt MkDog = 1

-- Genuinely polymorphic over `a` -- the `Greeter a` dictionary is
-- passed as a real runtime value and each method is projected out of
-- it at runtime (`case`-destructure + `apply`), never specialised away
-- per instantiation. This is what forces the instance dictionary
-- itself to exist as a real constant value in the first place, rather
-- than every method call resolving straight to `greet_Dog`/etc.
-- directly with no dictionary involved at all.
useGreeter : Greeter a => a -> String
useGreeter x = greet x ++ " / " ++ loud x ++ " x" ++ show (cnt x)

main : IO ()
main = putStrLn (useGreeter MkDog)
