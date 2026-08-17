module Compiler.RC2.ConAltNative

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Optimizes constructor-destructured fields by caching them into
-- native shadows. This improves performance by avoiding repeated
-- box unwrapping, while maintaining correct ownership tracking for
-- the original boxed fields.
-- Existing ownership decisions from earlier passes (Compiler.RC2.RC's
-- `annotate`, Compiler.RC2.Reuse's `resolveAlt`) stay completely
-- untouched by this pass -- it runs
-- strictly after both (see RC2.idr's own toRCDefs) and only ever
-- *adds* a wrapping RLet (the shadow) plus an explicit RDrop for the
-- field's own single remaining (post-rename) use; it never edits an
-- existing ownership node's own meaning, only renames what a handful
-- of them refer to (exactly what `renameRCExp`/`stripOwnership`'s own
-- established contract already covers, reused here rather than a
-- fresh implementation of the same idea).
--
-- Unlike a promoted top-level loop parameter (which becomes wholly
-- dead after promotion -- every reference, Boxed or native, redirects
-- to the shadow), a destructured field can still have a genuinely
-- separate, unrelated Boxed-context use in the same alt (e.g.
-- `case acc of MkAcc x y => f x (show y)` -- `x`'s own native use and
-- `y`'s own Boxed use coexist). This still doesn't need special-casing
-- here: `renameRCExp` redirects *every* reference (Boxed-context ones
-- included) to the shadow, and any surviving Boxed-context read of the
-- shadow gets re-boxed on demand by `rcVarToBoxedC`'s own already-
-- established `RNative` case -- a fresh allocation instead of sharing
-- the one the constructor's own field used to hold, invisible to any
-- Idris-level program (scalars have no observable identity, the same
-- reasoning `doc/dual-abi.md`'s own `nativePromotionFor` write-up
-- already relies on for the analogous RLet case).

import Compiler.RC2.RCExp
import Compiler.RC2.Types
import Compiler.RC2.Loop

import Core.CompileExpr
import Core.FC
import Core.TT

import Data.List
import Data.SortedMap
import Data.SortedSet

%default covering

||| Assign consecutive fresh ids, starting at `nextId`, to each eligible
||| `(p, ty)` pair -- mirrors `Compiler.RC2.Loop`'s own private
||| `assignShadowIds` exactly (not exported there, so re-declared here
||| rather than exporting a one-line helper across a module boundary
||| just for this).
assignShadowIds : (nextId : Int) -> List (Int, PrimType) -> List (Int, Int, PrimType)
assignShadowIds _ [] = []
assignShadowIds nextId ((p, ty) :: rest) = (p, nextId, ty) :: assignShadowIds (nextId + 1) rest

||| Peel every leading `RDup`/`RDrop`/`RFree`/`RReleaseReuse`/
||| `RReuseOffer` node -- `Compiler.RC2.RC`'s own `annotate` /
||| `Compiler.RC2.Reuse`'s own `resolveAlt` output, always already fully
||| resolved and in place by the time this pass runs -- off the front of
||| an alt's own body, returning a rebuilding function alongside the
||| "core" underneath: the point past which this alt's own real
||| computation begins, and the *only* safe point to insert a native
||| shadow read (and its own eventual drop). Inserting any earlier --
||| the first, buggier version of this function did exactly that,
||| wrapping the *whole* alt body including a leading `RReuseOffer` --
||| reads and drops the field before `Compiler.RC2.Reuse`'s own
||| uniqueness check has even run, which independently, unconditionally
||| `idris2rc2_dup`s every `RReuseOffer`'s own con-arg regardless of
||| which branch it takes (`Compiler.RC2.Emit`'s own `branchBody`, see
||| its own doc comment) whenever the alt's body it's handed doesn't
||| *structurally start with* `RReuseOffer` -- an early field read
||| satisfies that condition by construction, silently defeating the
||| whole reuse mechanism's own "just drop these unconditionally,
||| they're already covered by the reuse offer that comes right after"
||| assumption, and leaking every reused field's own reboxed value one
||| allocation at a time. Confirmed with `valgrind --leak-check=full`
||| against `tests/Test12ConAltNative.idr`'s own `step` (destructures
||| and immediately reconstructs the same shape) before landing on this
||| fix -- see TODO.md's own entry for the full history.
peelWrappers : RCExp -> (RCExp -> RCExp, RCExp)
peelWrappers (RDup fc v cont) =
    let (rebuild, core) = peelWrappers cont in (\c => RDup fc v (rebuild c), core)
peelWrappers (RDrop fc vs cont) =
    let (rebuild, core) = peelWrappers cont in (\c => RDrop fc vs (rebuild c), core)
peelWrappers (RFree fc v cont) =
    let (rebuild, core) = peelWrappers cont in (\c => RFree fc v (rebuild c), core)
peelWrappers (RReleaseReuse fc v cont) =
    let (rebuild, core) = peelWrappers cont in (\c => RReleaseReuse fc v (rebuild c), core)
peelWrappers (RReuseOffer fc sc dupOnShared cont) =
    let (rebuild, core) = peelWrappers cont in (\c => RReuseOffer fc sc dupOnShared (rebuild c), core)
peelWrappers e = (id, e)

||| Promote whichever of `argIds` (one alt's own destructured fields)
||| `nativeArgType` finds read as a native-context operand somewhere in
||| this alt's own "core" (past every leading ownership/reuse wrapper,
||| see `peelWrappers`), consistently -- same eligibility question, same
||| `assignShadowIds`/rename/strip shape as `Compiler.RC2.Loop`'s own
||| `applyLoop`, batched across every eligible field in one combined
||| rename/strip pass rather than one at a time (avoids re-scanning
||| `core` from scratch after each individual promotion). Wraps `core`
||| (never the wrappers `peelWrappers` already split off -- those stay
||| completely untouched, not even renamed into, so a reuse decision
||| already made there is never disturbed) in one `RLet`+`RDrop` pair
||| per promoted field: the `RLet` reads the original (still fully
||| Boxed, still fully owned) field exactly once, natively, into the
||| fresh shadow; the `RDrop` immediately after releases the original --
||| now provably dead within `core`, since every other reference to it
||| there was just renamed away -- rather than leaving whatever later
||| drop position (typically an `ROp`'s own `postDrop` entry)
||| `Compiler.RC2.RC`'s own `annotate` had originally chosen within
||| `core` (now stale, and already stripped along with every other
||| piece of `core`'s own bookkeeping `renameRCExp` carried over to the
||| shadow's own id).
shadowAltFields : (nextId : Int) -> List Int -> RCExp -> (Int, RCExp)
shadowAltFields nextId argIds body =
    let (rebuild, core) = peelWrappers body
        eligible : List (Int, PrimType)
        eligible = mapMaybe (\p => map (p,) (nativeArgType p core)) argIds
    in case eligible of
            [] => (nextId, body)
            _ =>
              let shadowed : List (Int, Int, PrimType)
                  shadowed = assignShadowIds nextId eligible
                  renaming : Renaming
                  renaming = SortedMap.fromList $ map (\(p, sid, _) => (p, sid)) shadowed
                  shadowIds : SortedSet Int
                  shadowIds = SortedSet.fromList $ map (\(_, sid, _) => sid) shadowed
                  renamedCore : RCExp
                  renamedCore = stripOwnership shadowIds (renameRCExp renaming core)
                  wrappedCore : RCExp
                  wrappedCore = foldr (\(p, sid, ty), acc =>
                                      RLet emptyFC sid (RNative ty) (RV emptyFC (RCLoc p))
                                        (RDrop emptyFC [RCLoc p] acc))
                                   renamedCore shadowed
              in (nextId + cast (length eligible), rebuild wrappedCore)

mutual
  ||| Walks the *whole* tree (not just tail positions -- an `RConCase`
  ||| can appear anywhere), threading a single fresh-id counter so
  ||| every promoted field anywhere in one definition gets its own
  ||| distinct shadow id, the same "one arithmetic maximum, threaded
  ||| onward" style `Compiler.RC2.Loop`'s own `applyLoop` uses for its
  ||| own (function-scoped, not tree-wide) shadow ids.
  applyConAltNativeExp : (nextId : Int) -> RCExp -> (Int, RCExp)
  applyConAltNativeExp nextId (RLet fc var rep value body) =
      let (nextId1, value') = applyConAltNativeExp nextId value
          (nextId2, body') = applyConAltNativeExp nextId1 body
      in (nextId2, RLet fc var rep value' body')
  applyConAltNativeExp nextId (RCmpCase fc op args postDrop t f) =
      let (nextId1, t') = applyConAltNativeExp nextId t
          (nextId2, f') = applyConAltNativeExp nextId1 f
      in (nextId2, RCmpCase fc op args postDrop t' f')
  applyConAltNativeExp nextId (RConCase fc sc alts mDef) =
      let (nextId1, alts') = applyConAltNativeAlts nextId alts
          (nextId2, mDef') = applyConAltNativeMaybe nextId1 mDef
      in (nextId2, RConCase fc sc alts' mDef')
  applyConAltNativeExp nextId (RConstCase fc sc alts mDef) =
      let (nextId1, alts') = applyConAltNativeConstAlts nextId alts
          (nextId2, mDef') = applyConAltNativeMaybe nextId1 mDef
      in (nextId2, RConstCase fc sc alts' mDef')
  applyConAltNativeExp nextId (RDup fc v body) =
      let (n, body') = applyConAltNativeExp nextId body in (n, RDup fc v body')
  applyConAltNativeExp nextId (RDrop fc vs body) =
      let (n, body') = applyConAltNativeExp nextId body in (n, RDrop fc vs body')
  applyConAltNativeExp nextId (RFree fc v body) =
      let (n, body') = applyConAltNativeExp nextId body in (n, RFree fc v body')
  applyConAltNativeExp nextId (RReleaseReuse fc v body) =
      let (n, body') = applyConAltNativeExp nextId body in (n, RReleaseReuse fc v body')
  applyConAltNativeExp nextId (RReuseOffer fc sc dupOnShared body) =
      let (n, body') = applyConAltNativeExp nextId body in (n, RReuseOffer fc sc dupOnShared body')
  -- Every other shape (RV, RAppName, RUnderApp, RApp, RCon, ROp,
  -- RExtPrim, RPrimVal, RErased, RCrash, RLoopContinue, RAppNameRep --
  -- and RLoop, though this pass runs strictly before
  -- Compiler.RC2.Loop/MutualLoop ever produce one, see RC2.idr's own
  -- toRCDefs): no further RCExp to recurse into.
  applyConAltNativeExp nextId e = (nextId, e)

  applyConAltNativeMaybe : Int -> Maybe RCExp -> (Int, Maybe RCExp)
  applyConAltNativeMaybe nextId Nothing = (nextId, Nothing)
  applyConAltNativeMaybe nextId (Just e) =
      let (n, e') = applyConAltNativeExp nextId e in (n, Just e')

  applyConAltNativeAlts : Int -> List RConAlt -> (Int, List RConAlt)
  applyConAltNativeAlts nextId [] = (nextId, [])
  applyConAltNativeAlts nextId (alt :: rest) =
      let (nextId1, alt') = applyConAltNativeAlt nextId alt
          (nextId2, rest') = applyConAltNativeAlts nextId1 rest
      in (nextId2, alt' :: rest')

  -- Recurse into this alt's own body first (promoting any more deeply
  -- nested alt's own fields), then promote this alt's own fields --
  -- the two are independent (disjoint id namespaces, and
  -- `nativeArgType`'s own scan only ever looks for a *specific* id's
  -- own uses) so the order between them doesn't affect the outcome,
  -- only which shadow ids end up numerically first.
  applyConAltNativeAlt : Int -> RConAlt -> (Int, RConAlt)
  applyConAltNativeAlt nextId (MkRConAlt name ci tag args body) =
      let (nextId1, body1) = applyConAltNativeExp nextId body
          (nextId2, body2) = shadowAltFields nextId1 args body1
      in (nextId2, MkRConAlt name ci tag args body2)

  applyConAltNativeConstAlts : Int -> List RConstAlt -> (Int, List RConstAlt)
  applyConAltNativeConstAlts nextId [] = (nextId, [])
  applyConAltNativeConstAlts nextId (MkRConstAlt c body :: rest) =
      let (nextId1, body') = applyConAltNativeExp nextId body
          (nextId2, rest') = applyConAltNativeConstAlts nextId1 rest
      in (nextId2, MkRConstAlt c body' :: rest')

||| Apply constructor-destructured-field native shadowing to one
||| top-level definition. Fresh shadow ids start one past the highest
||| id already used anywhere in the definition (own top-level `args`,
||| plus every `RLet`/`RConAlt`-bound id in `body`, via
||| `Compiler.RC2.Loop`'s own `collectBoundIds`) -- same reasoning
||| `applyLoop` already uses for its own shadow ids: a plain arithmetic
||| maximum is enough since this whole pass stays a pure function of
||| one definition at a time, no cross-definition state needed.
export
applyConAltNative : RCDef -> RCDef
applyConAltNative (MkRCFun args retRep body) =
    let argIds = map fst args
        nextId = the Int (1 + foldl max (-1) (argIds ++ collectBoundIds body))
        (_, body') = applyConAltNativeExp nextId body
    in MkRCFun args retRep body'
applyConAltNative (MkRCError body) =
    let nextId = the Int (1 + foldl max (-1) (collectBoundIds body))
        (_, body') = applyConAltNativeExp nextId body
    in MkRCError body'
applyConAltNative d@(MkRCCon _ _ _) = d
applyConAltNative d@(MkRCForeign _ _ _) = d
