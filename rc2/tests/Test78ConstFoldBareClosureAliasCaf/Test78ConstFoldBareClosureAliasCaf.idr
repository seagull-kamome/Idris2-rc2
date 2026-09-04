module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for Compiler.RC2.ConstFold's `foldConst` on a BARE
-- closure-alias CAF: upstream idris2-src's own Compiler.Opts.CSE pass
-- (its module doc: "move duplicate expressions introduced during
-- autosearch ... to the top level") hoists the repeated, resolved
-- `decEq` dictionary reference below (`DecEq (Maybe Nat)`'s own
-- `decEq` needs `DecEq Nat`'s dictionary passed in, and `checkPair`
-- calls `decEq` at that same type twice) into a fresh top-level
-- `csegen:N` CAF whose ENTIRE BODY -- confirmed via
-- `idris2 --dumplifted` -- is `<name underapp 2>()`, i.e. a bare,
-- zero-capture `LUnderApp`/`RUnderApp` with no enclosing `let` at all.
-- This is the exact shape (missing=2, args=[]) diagnosed in the wild
-- in idris2-missing-containers's `Main.idr` (`csegen:23 = decEq`,
-- called repeatedly from `Main.testHashMap`) -- CSE is what produces a
-- genuinely point-free top-level CAF here, unlike an ordinary
-- user-written alias (`aliasedOp = op1`), which idris2-src's own
-- lambda-lifting eta-expands to a normal 1-arg function before rc2
-- ever sees it (confirmed by hand via `--dumplifted`: a user-written
-- alias's own `LiftedDef` args always carry a synthetic `{ext:0}`
-- binder, never staying genuinely zero-arg).
--
-- Before the fix, `foldConst`'s top-level `RUnderApp fc n missing args`
-- arm only resolved `args`, never reclassifying the whole node into
-- `RCConstClosure` -- so `cafValueOf`'s `MkRCFun [] _ _ (RV _ cval)`
-- pattern (RC2.idr) never matched the `csegen` CAF, it never entered
-- `CafTable`, and both call sites below kept a real `RAppName ...
-- {csegen:N} []` / `call {csegen:N} []` CAF lookup instead of
-- referencing the shared closure constant directly. Confirmed by hand
-- via `--directive dumprcexpr` pre-fix: `def {csegen:N} (fun args=[]
-- ret=Boxed) / partial {{csegen:N}:0} missing=2 []`, with both call
-- sites in `Main.checkPair` still showing `call {csegen:N} []`.
--
-- Confirmed by hand via `--directive dumprcexpr` post-fix: the CAF's
-- own definition now dumps as a `RCConstClosure` value (the `~closure`
-- `Show` form), and both call sites reference it directly rather than
-- via a repeated `RAppName`/`call {csegen:N} []`.

import Decidable.Equality

checkPair : Maybe Nat -> Maybe Nat -> Maybe Nat -> Maybe Nat -> Bool
checkPair a b c d =
    case decEq a b of
         Yes _ => True
         No _ => case decEq c d of
                      Yes _ => True
                      No _ => False

main : IO ()
main = printLn (checkPair (Just 3) (Just 3) (Just 4) (Just 5))
