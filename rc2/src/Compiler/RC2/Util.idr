module Compiler.RC2.Util

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Small, dependency-light helpers shared by two or more other
-- Compiler.RC2 modules with nothing else in common -- each used to be
-- duplicated (byte-identical or near so) at its call sites until a
-- second/third copy turned up. Kept leaf-level on purpose: this module
-- must never depend on anything beyond Compiler.RC2.RCExp/Types, so
-- every existing pass module stays free to import it without risking
-- an import cycle.

import Compiler.RC2.RCExp
import Compiler.RC2.Types

import Core.CompileExpr
import Core.Core
import Core.TT

import Data.SortedMap
import Data.Vect

%default total

||| Plain recursive Vect traversal in Core, not the standard `traverse`:
||| multiple `traverse`/`Applicative Core` candidates already in scope
||| at most call sites make `traverse f (args : Vect n a)` fail to
||| resolve at all ("Can't find an implementation for Applicative
||| Core") rather than picking `Traversable (Vect n)`.
export
rc2traverseVect : (a -> Core b) -> Vect n a -> Core (Vect n b)
rc2traverseVect f [] = pure []
rc2traverseVect f (x :: xs) = do
    x' <- f x
    xs' <- rc2traverseVect f xs
    pure (x' :: xs')

||| RC.idr wraps a branch/scope body in a leading `RDrop` node whenever
||| there are dead owned variables at its entry. Peel it off so its
||| drop list can be inspected/refined by a later pass instead of
||| unconditionally emitting the drops as-is.
export
peelDrop : RCExp -> (List RCLocal, RCExp)
peelDrop (RDrop _ locs cont) = (locs, cont)
peelDrop e = ([], e)

||| Assign consecutive fresh ids, starting at `nextId`, to each eligible
||| `(p, ty)` pair -- pairing each original id with its own shadow id
||| and the native type it was found eligible at.
export
assignShadowIds : (nextId : Int) -> List (Int, PrimType) -> List (Int, Int, PrimType)
assignShadowIds _ [] = []
assignShadowIds nextId ((p, ty) :: rest) = (p, nextId, ty) :: assignShadowIds (nextId + 1) rest

||| `RCLocal`'s own representation, given `reps` -- the "missing id
||| defaults to `RBoxed`" convention every caller relies on (a
||| top-level function argument, or an as-yet-unseen bound local, is
||| always genuinely Boxed at that point -- `reps` only ever records a
||| *promotion* away from that default). The same lookup
||| `Compiler.RC2.EmitUtil`'s own (`Core`-monadic, `RepMap`-backed)
||| `repOfLocal` performs at emission time, just written as a pure
||| function here for passes that have no `Core` context of their own
||| to thread a ref through.
export
localRepIn : SortedMap Int Rep -> RCLocal -> Rep
localRepIn _ RCNull = RBoxed
localRepIn reps (RCLoc i) = fromMaybe RBoxed (lookup i reps)
localRepIn _ (RCConst c) = fromMaybe RBoxed (RNative <$> litRep c)
localRepIn _ (RCEmptyCon {}) = RBoxed
localRepIn _ (RCConstCon {}) = RBoxed
