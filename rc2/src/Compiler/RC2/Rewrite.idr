||| Whole-tree rewrites over `RCExp` that several passes share: tail-call
||| rewriting, local/binder renaming and ownership stripping. Split out of
||| `Compiler.RC2.Loop`, which only needed them itself in part.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Compiler.RC2.Rewrite

import Compiler.RC2.RCExp

import Core.TT

import Data.List
import Data.List1
import Data.SortedMap
import Data.SortedSet
import Data.Vect

%default covering

||| What `mapTailAppNames` collects on the way down: the tail-call targets seen
||| and whether any call was rewritten.
record TailSeen where
    constructor MkTailSeen
    names : SortedSet Name
    rewritten : Bool

Semigroup TailSeen where
    MkTailSeen n1 r1 <+> MkTailSeen n2 r2 = MkTailSeen (union n1 n2) (r1 || r2)

Monoid TailSeen where
    neutral = MkTailSeen empty False

||| Rewrite every tail-position, non-lazy `RAppName fc Nothing n args` leaf for
||| which `f fc n args` returns `Just e'`, substituting `e'`. Returns the set of
||| visited tail-call target names, whether any rewrite happened, and the tree.
||| Shared by `Loop` and `MutualLoop` so both agree on what a tail position is.
||| See `rc2/doc/loop-conversion.md`'s "`mapTailAppNames`".
export
mapTailAppNames : (FC -> Name -> List RCLocal -> Maybe RCExp) -> RCExp -> (SortedSet Name, Bool, RCExp)
mapTailAppNames f e = let (MkTailSeen ns r, e') = go e in (ns, r, e')
  where
    go : RCExp -> (TailSeen, RCExp)
    go e@(RAppName fc Nothing n args) =
        case f fc n args of
             Just e' => (MkTailSeen (singleton n) True, e')
             Nothing => (MkTailSeen (singleton n) False, e)
    go e = fromMaybe (neutral, e) (traverseTailChildren go e)

------------------------------------------------------------------------
-- Renaming every RCLocal/bound-id occurrence in a body according to a
-- (possibly partial -- ids with no entry pass through unchanged) map.
-- A pure substitution: doesn't add or remove any RDup/RDrop/RFree/
-- RReleaseReuse/reuse-related node, just relabels what they (and every
-- read) refer to.

public export
Renaming : Type
Renaming = SortedMap Int Int

renameId : Renaming -> Int -> Int
renameId ren i = fromMaybe i (lookup i ren)

renameLocal : Renaming -> RCLocal -> RCLocal
renameLocal ren (RCLoc i) = RCLoc (renameId ren i)
renameLocal _ l = l

renameMaybeLocal : Renaming -> Maybe RCLocal -> Maybe RCLocal
renameMaybeLocal ren = map (renameLocal ren)


-- Applies `f` to every local read and `g` to every id a node binds, nothing else.
mutual
  export
  mapLocalsRCExp : (RCLocal -> RCLocal) -> (Int -> Int) -> RCExp -> RCExp
  mapLocalsRCExp f g (RV fc v) = RV fc (f v)
  mapLocalsRCExp f g (RAppName fc lazy n args) = RAppName fc lazy n (map f args)
  mapLocalsRCExp f g (RUnderApp fc n missing args) = RUnderApp fc n missing (map f args)
  mapLocalsRCExp f g (RDelay fc lr n caps) = RDelay fc lr n (map f caps)
  mapLocalsRCExp f g (RApp fc lazy c args) = RApp fc lazy (f c) (map (f) args)
  mapLocalsRCExp f g (RLet fc var rep value body) =
      RLet fc (g var) rep (mapLocalsRCExp f g value) (mapLocalsRCExp f g body)
  mapLocalsRCExp f g (RCon fc n ci tag args reuseFrom) =
      RCon fc n ci tag (map f args) (map f reuseFrom)
  mapLocalsRCExp f g (RRetPack fc n tag fields) = RRetPack fc n tag (map f fields)
  mapLocalsRCExp f g (ROp fc lazy op args postDrop) =
      ROp fc lazy op (map f args) (map f postDrop)
  mapLocalsRCExp f g (RExtPrim fc lazy p args postDrop) =
      RExtPrim fc lazy p (map f args) (map f postDrop)
  mapLocalsRCExp f g (RStructGet fc structVar sf postDrop) =
      RStructGet fc (f structVar) sf (map f postDrop)
  mapLocalsRCExp f g (RForce fc lr v postDrop) =
      RForce fc lr (f v) (map f postDrop)
  mapLocalsRCExp f g (RStructSet fc structVar sf value postDrop) =
      RStructSet fc (f structVar) sf (f value) (map f postDrop)
  mapLocalsRCExp f g (RFill fc cell k value postDrop) =
      RFill fc (f cell) k (f value) (map f postDrop)
  mapLocalsRCExp f g (RCmpCase fc op args postDrop whenTrue whenFalse) =
      RCmpCase fc op (map f args) (map f postDrop) (mapLocalsRCExp f g whenTrue) (mapLocalsRCExp f g whenFalse)
  mapLocalsRCExp f g (RConCase fc sc alts mDef) =
      RConCase fc (f sc) (map (mapLocalsConAlt f g) alts) (map (mapLocalsRCExp f g) mDef)
  mapLocalsRCExp f g (RConstCase fc sc alts mDef) =
      RConstCase fc (f sc) (map (mapLocalsConstAlt f g) alts) (map (mapLocalsRCExp f g) mDef)
  mapLocalsRCExp _ _ (RPrimVal fc c) = RPrimVal fc c
  mapLocalsRCExp _ _ (RErased fc) = RErased fc
  mapLocalsRCExp _ _ (RCrash fc msg) = RCrash fc msg
  mapLocalsRCExp f g (RDup fc v extra body) = RDup fc (f v) extra (mapLocalsRCExp f g body)
  mapLocalsRCExp f g (RDrop fc vars body) = RDrop fc (map f vars) (mapLocalsRCExp f g body)
  mapLocalsRCExp f g (RFree fc v body) = RFree fc (f v) (mapLocalsRCExp f g body)
  mapLocalsRCExp f g (RReleaseReuse fc v body) = RReleaseReuse fc (f v) (mapLocalsRCExp f g body)
  mapLocalsRCExp f g (RReuseOffer fc sc dupOnShared dropOnUnique body) =
      RReuseOffer fc (f sc) (map f dupOnShared) (map f dropOnUnique) (mapLocalsRCExp f g body)
  -- Never actually reached in practice -- nothing calling this ever
  -- operates on a tree that already contains an `RLoop` (this module's
  -- own `applyLoop` is its sole producer, and only ever calls
  -- `renameRCExp` on a not-yet-wrapped body). Kept total (as a plain
  -- pass-through) rather than assumed unreachable, same reasoning as
  -- RC.idr's own `annotate`.
  mapLocalsRCExp f g (RLoop fc loopParams initial prologueDrop body) =
      RLoop fc (map (\(i, r) => (g i, r)) loopParams) (map f initial) (map f prologueDrop) (mapLocalsRCExp f g body)
  mapLocalsRCExp f g (RLoopContinue fc args postDrop) = RLoopContinue fc (map f args) (map f postDrop)
  -- Never actually reached in practice -- Compiler.RC2.DualABI, the
  -- sole producer of RAppNameRep, runs strictly after both this
  -- module and Compiler.RC2.MutualLoop (the only two callers of
  -- renameRCExp) have already finished. Kept total (as a plain
  -- pass-through) rather than assumed unreachable, same reasoning as
  -- this function's own RLoop case just above.
  mapLocalsRCExp f g (RAppNameRep fc n argReps retRep postDrop args) =
      RAppNameRep fc n argReps retRep (map f postDrop) (map f args)
  -- Never actually reached in practice, same reasoning as RAppNameRep
  -- just above -- Compiler.RC2.DualABI's own FFI-inline pass runs even
  -- later than RAppNameRep's own producer (Stage 4), strictly after
  -- both this module and Compiler.RC2.MutualLoop have already
  -- finished.
  mapLocalsRCExp f g (RAppFFIInline fc ccs fargs ret postDrop args) =
      RAppFFIInline fc ccs fargs ret (map f postDrop) (map f args)
  -- Never actually reached in practice -- RMemoize only ever wraps a
  -- 0-argument CAF's own whole body (doc/caf-memoization.md), and this
  -- module's own applyLoop only ever runs on a definition with real
  -- loop-carried parameters. Kept total (as a plain pass-through), same
  -- reasoning as RAppNameRep/RAppFFIInline just above.
  mapLocalsRCExp f g (RMemoize fc n rep body) = RMemoize fc n rep (mapLocalsRCExp f g body)

  mapLocalsConAlt : (RCLocal -> RCLocal) -> (Int -> Int) -> RConAlt -> RConAlt
  mapLocalsConAlt f g (MkRConAlt name ci tag args body) =
      MkRConAlt name ci tag (map (g) args) (mapLocalsRCExp f g body)

  mapLocalsConstAlt : (RCLocal -> RCLocal) -> (Int -> Int) -> RConstAlt -> RConstAlt
  mapLocalsConstAlt f g (MkRConstAlt c body) = MkRConstAlt c (mapLocalsRCExp f g body)

||| `mapLocalsRCExp` for a renaming.
export
renameRCExp : Renaming -> RCExp -> RCExp
renameRCExp ren = mapLocalsRCExp (renameLocal ren) (renameId ren)


||| Whether `v` survives `stripOwnership`'s own filtering -- kept
||| (`True`) unless it names one of `ids`; a non-`RCLoc` local (a
||| constant/`NULL`/tagged-empty-con) is never one of `ids` to begin
||| with and always survives.
keepUnlessOwned : SortedSet Int -> RCLocal -> Bool
keepUnlessOwned ids (RCLoc i) = not (contains i ids)
keepUnlessOwned _ _ = True

||| Remove every `RDup`/`RDrop`/`RFree` target, and every `ROp`/`RCmpCase`
||| `postDrop` entry, naming one of `ids`. Precondition: every value-reading
||| occurrence of each id is already native. `RCon` fields, case scrutinees and
||| `RReuseOffer` operands are deliberately left alone.
||| See `rc2/doc/loop-conversion.md`'s "`stripOwnership`".
export
stripOwnership : SortedSet Int -> RCExp -> RCExp
stripOwnership ids (RDup fc v extra body) =
    let body' = stripOwnership ids body
    in if keepUnlessOwned ids v then RDup fc v extra body' else body'
stripOwnership ids (RDrop fc vs body) =
    let vs' = filter (keepUnlessOwned ids) vs
        body' = stripOwnership ids body
    in if null vs' then body' else RDrop fc vs' body'
stripOwnership ids (RFree fc v body) =
    let body' = stripOwnership ids body
    in if keepUnlessOwned ids v then RFree fc v body' else body'
stripOwnership ids (RLet fc var rep value body) =
    RLet fc var rep (stripOwnership ids value) (stripOwnership ids body)
stripOwnership ids (ROp fc lazy op args postDrop) =
    ROp fc lazy op args (filter (keepUnlessOwned ids) postDrop)
stripOwnership ids (RCmpCase fc op args postDrop t f) =
    RCmpCase fc op args (filter (keepUnlessOwned ids) postDrop)
      (stripOwnership ids t) (stripOwnership ids f)
stripOwnership ids (RConCase fc sc alts mDef) =
    RConCase fc sc (map (\(MkRConAlt n ci tag as body) => MkRConAlt n ci tag as (stripOwnership ids body)) alts)
      (map (stripOwnership ids) mDef)
stripOwnership ids (RConstCase fc sc alts mDef) =
    RConstCase fc sc (map (\(MkRConstAlt c body) => MkRConstAlt c (stripOwnership ids body)) alts)
      (map (stripOwnership ids) mDef)
stripOwnership ids (RReleaseReuse fc v body) = RReleaseReuse fc v (stripOwnership ids body)
stripOwnership ids (RReuseOffer fc sc dupOnShared dropOnUnique body) = RReuseOffer fc sc dupOnShared dropOnUnique (stripOwnership ids body)
stripOwnership ids (RLoopContinue fc args postDrop) =
    RLoopContinue fc args (filter (keepUnlessOwned ids) postDrop)
-- Unlike every other case in this module, `RLoop` genuinely does show up
-- here: `Compiler.RC2.DualABI`'s own `synthesizeWorker` calls this
-- function over a whole worker body that may already be `RLoop`-wrapped
-- (by this same module's own `applyLoop`, having already run earlier in
-- the pipeline). `loopParams`/`initial` need no filtering of their own
-- (a promoted top-level param's shadow id was already minted fresh by
-- `applyLoop` and never re-promoted itself), but `prologueDrop` must be
-- filtered exactly like an ordinary `RDrop`'s var list above, or a
-- worker whose own signature now renders one of these ids natively
-- would still emit a drop for a value that was never boxed in that
-- worker's own rendering at all.
stripOwnership ids (RLoop fc loopParams initial prologueDrop body) =
    RLoop fc loopParams initial
      (filter (keepUnlessOwned ids) prologueDrop)
      (stripOwnership ids body)
stripOwnership ids (RStructGet fc structVar sf postDrop) =
    RStructGet fc structVar sf (filter (keepUnlessOwned ids) postDrop)
stripOwnership ids (RForce fc lr v postDrop) =
    RForce fc lr v (filter (keepUnlessOwned ids) postDrop)
stripOwnership ids (RStructSet fc structVar sf value postDrop) =
    RStructSet fc structVar sf value (filter (keepUnlessOwned ids) postDrop)
stripOwnership ids (RFill fc cell k value postDrop) =
    RFill fc cell k value (filter (keepUnlessOwned ids) postDrop)
-- A worker call made before the promotion (struct return, doc/struct-return.md)
-- already lists its Boxed arguments in `postDrop`.
stripOwnership ids (RAppNameRep fc n argReps retRep postDrop args) =
    RAppNameRep fc n argReps retRep (filter (keepUnlessOwned ids) postDrop) args
stripOwnership ids (RExtPrim fc lazy p args postDrop) =
    RExtPrim fc lazy p args (filter (keepUnlessOwned ids) postDrop)
-- RV, RAppName, RUnderApp, RApp, RCon, RPrimVal, RErased, RCrash: no
-- ownership-tracking positions of their own.
stripOwnership _ e = e
