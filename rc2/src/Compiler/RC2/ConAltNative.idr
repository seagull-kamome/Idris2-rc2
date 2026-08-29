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
-- *adds* a wrapping RLet (the shadow); it never edits an existing
-- ownership node's own meaning for any local other than the field
-- being promoted itself.
--
-- Unlike a promoted top-level loop parameter (which becomes wholly
-- dead after promotion -- every reference, Boxed or native, redirects
-- to the shadow), a destructured field can still have a genuinely
-- separate, unrelated Boxed-context use in the same alt (e.g.
-- `case acc of MkAcc x y => f x (show y)` -- `x`'s own native use and
-- `y`'s own Boxed use coexist). Rather than redirecting *every*
-- reference (Boxed-context ones included) to the shadow and letting a
-- surviving Boxed-context read get re-boxed fresh on demand every time
-- (an earlier version of this pass did exactly that -- see TODO.md's
-- own "Performance: reboxing a native-shadowed value always allocates
-- fresh" entry for why that's wasteful and how this was found), this
-- pass redirects only the native-context occurrences
-- (`markNativeOccurrences`) and rebuilds ownership for whichever
-- Boxed-context occurrences of the original field survive
-- (`reannotateFieldOwnership`) -- so a Boxed-context read of `x` above
-- keeps sharing the original field's own identity via an ordinary
-- `dup`/move, the same as it would have without this pass running at
-- all, while the native-context reads still get cached into a single
-- shadow.

import Compiler.RC2.RCExp
import Compiler.RC2.Types
import Compiler.RC2.Loop
import Compiler.RC2.Util

import Core.CompileExpr
import Core.FC
import Core.TT

import Data.List
import Data.SortedMap
import Data.SortedSet
import Data.Vect

%default covering

||| Peel every leading `RDup`/`RDrop`/`RFree`/`RReleaseReuse`/
||| `RReuseOffer` node -- `Compiler.RC2.RC`'s own `annotate` /
||| `Compiler.RC2.Reuse`'s own `resolveAlt` output, always already fully
||| resolved and in place by the time this pass runs -- off the front of
||| an alt's own body, returning a rebuilding function alongside the
||| "core" underneath: the point past which this alt's own real
||| computation begins, and the *only* safe point to insert a native
||| shadow read (and its own eventual drop). Must be inserted past every
||| leading wrapper, never before -- reading/dropping the field earlier
||| runs ahead of `Compiler.RC2.Reuse`'s own uniqueness check, silently
||| defeating reuse. See rc2/doc/con-alt-native.md's "Bugs found and
||| fixed" #2 for the leak this caused before this fix existed.
peelWrappers : RCExp -> (RCExp -> RCExp, RCExp)
peelWrappers (RDup fc v cont) =
    let (rebuild, core) = peelWrappers cont in (\c => RDup fc v (rebuild c), core)
peelWrappers (RDrop fc vs cont) =
    let (rebuild, core) = peelWrappers cont in (\c => RDrop fc vs (rebuild c), core)
peelWrappers (RFree fc v cont) =
    let (rebuild, core) = peelWrappers cont in (\c => RFree fc v (rebuild c), core)
peelWrappers (RReleaseReuse fc v cont) =
    let (rebuild, core) = peelWrappers cont in (\c => RReleaseReuse fc v (rebuild c), core)
peelWrappers (RReuseOffer fc sc dupOnShared dropOnUnique cont) =
    let (rebuild, core) = peelWrappers cont in (\c => RReuseOffer fc sc dupOnShared dropOnUnique (rebuild c), core)
peelWrappers e = (id, e)

------------------------------------------------------------------------
-- Reusing the original Boxed field when it's *also* read in a Boxed
-- context, instead of always reboxing fresh (see TODO.md's own
-- "Performance: reboxing a native-shadowed value always allocates
-- fresh" entry). `markNativeOccurrences` renames only the
-- native-context occurrences of a field (mirroring `Loop.idr`'s own
-- `nativeArgTypes`/`opNativeUsesThrough` walk exactly) to the fresh
-- shadow id, leaving every Boxed-context occurrence on the original
-- field id untouched; `reannotateFieldOwnership` then rebuilds
-- ownership (dup/drop) for just that field id, from scratch, using the
-- same "first occurrence moves, later ones dup" rule `RC.idr`'s own
-- `splitBorrows`/`annotate`/`branchBody` use -- run only after
-- `stripOwnership` has already cleared this field id's own stale
-- ownership bookkeeping (computed back when every occurrence, native
-- and Boxed alike, was still assumed to disappear into the shadow).

||| Mirrors `Loop.idr`'s own `opNativeUsesThrough` exactly, but rewrites
||| instead of collecting: once inside the `ROp` that a native-`Rep`
||| `RLet`'s own `value` peels down to (through `RDup`/`RDrop`/`RFree`/
||| `RReleaseReuse`/nested-`RLet`-`body` wrapping), redirect `fid`'s own
||| occurrences in that `ROp`'s own `args` to `sid`.
renameOpArgsThrough : (fid : Int) -> (sid : Int) -> RCExp -> RCExp
renameOpArgsThrough fid sid (ROp fc lazy op args postDrop) =
    ROp fc lazy op (map (\a => if a == RCLoc fid then RCLoc sid else a) args) postDrop
renameOpArgsThrough fid sid (RDup fc v cont) = RDup fc v (renameOpArgsThrough fid sid cont)
renameOpArgsThrough fid sid (RDrop fc vs cont) = RDrop fc vs (renameOpArgsThrough fid sid cont)
renameOpArgsThrough fid sid (RFree fc v cont) = RFree fc v (renameOpArgsThrough fid sid cont)
renameOpArgsThrough fid sid (RReleaseReuse fc v cont) = RReleaseReuse fc v (renameOpArgsThrough fid sid cont)
renameOpArgsThrough fid sid (RLet fc var rep value body) = RLet fc var rep value (renameOpArgsThrough fid sid body)
renameOpArgsThrough _ _ e = e

||| Mirrors `Loop.idr`'s own `nativeArgTypes` exactly (identical walk,
||| identical cases), but rewrites the native-context occurrences it
||| finds instead of collecting their types. Every Boxed-context
||| occurrence of `fid` (an `RCon`/`RAppName`/etc. operand -- anywhere
||| `nativeArgTypes` itself falls through to its own `_ = empty` case)
||| is left completely untouched here; `reannotateFieldOwnership`
||| handles those next.
markNativeOccurrences : (fid : Int) -> (sid : Int) -> RCExp -> RCExp
markNativeOccurrences fid sid (RLet fc var rep value body) =
    let value' = case rep of
                      RBoxed => value
                      _ => renameOpArgsThrough fid sid value
    in RLet fc var rep (markNativeOccurrences fid sid value') (markNativeOccurrences fid sid body)
markNativeOccurrences fid sid (RCmpCase fc op args postDrop t f) =
    RCmpCase fc op (map (\a => if a == RCLoc fid then RCLoc sid else a) args) postDrop
             (markNativeOccurrences fid sid t) (markNativeOccurrences fid sid f)
markNativeOccurrences fid sid (RDup fc v cont) = RDup fc v (markNativeOccurrences fid sid cont)
markNativeOccurrences fid sid (RDrop fc vs cont) = RDrop fc vs (markNativeOccurrences fid sid cont)
markNativeOccurrences fid sid (RFree fc v cont) = RFree fc v (markNativeOccurrences fid sid cont)
markNativeOccurrences fid sid (RReleaseReuse fc v cont) = RReleaseReuse fc v (markNativeOccurrences fid sid cont)
markNativeOccurrences fid sid (RReuseOffer fc sc dupOnShared dropOnUnique cont) =
    RReuseOffer fc sc dupOnShared dropOnUnique (markNativeOccurrences fid sid cont)
markNativeOccurrences fid sid (RConCase fc sc alts mDef) =
    RConCase fc sc (map (\(MkRConAlt n ci tag as body) => MkRConAlt n ci tag as (markNativeOccurrences fid sid body)) alts)
                    (map (markNativeOccurrences fid sid) mDef)
markNativeOccurrences fid sid (RConstCase fc sc alts mDef) =
    RConstCase fc sc (map (\(MkRConstAlt c body) => MkRConstAlt c (markNativeOccurrences fid sid body)) alts)
                      (map (markNativeOccurrences fid sid) mDef)
markNativeOccurrences _ _ e = e

||| How many `RDup`s an operand list needs for `fid`'s own occurrences
||| in it -- one dup per occurrence past the first, if `fid` is still
||| `owned` (the first occurrence moves); if `fid` is already spent,
||| every occurrence needs its own dup. The same rule `RC.idr`'s own
||| `splitBorrows` applies, specialised to counting a single local's
||| repeat occurrences within one operand list rather than partitioning
||| a whole set. Returns the updated ownership alongside the count.
countDupsNeeded : (fid : Int) -> Bool -> List RCLocal -> (Nat, Bool)
countDupsNeeded fid owned args =
    let occ = length (filter (== RCLoc fid) args)
    in case occ of
            0   => (0, owned)
            S k => if owned then (k, False) else (occ, False)

||| Nest `n` `RDup`s for `fid` around `e` -- `wrapDups`'s own
||| single-local, fixed-count specialisation.
wrapNDups : FC -> Int -> Nat -> RCExp -> RCExp
wrapNDups fc fid Z e = e
wrapNDups fc fid (S k) e = RDup fc (RCLoc fid) (wrapNDups fc fid k e)

mutual
  ||| Rebuild ownership for exactly `fid`, from scratch, over a body
  ||| whose every remaining occurrence of `fid` is now known to be a
  ||| genuine Boxed-context read (native-context ones were already
  ||| redirected by `markNativeOccurrences`, and stale bookkeeping for
  ||| `fid` was already cleared by `stripOwnership` before this ever
  ||| runs). Same "first occurrence moves, later ones dup" rule as
  ||| `RC.idr`'s own `annotate`/`splitBorrows`, `branchBody`'s own
  ||| per-arm drop-if-unused handling for `RConCase`/`RConstCase`'s own
  ||| alts -- just specialised to tracking a single local (`owned :
  ||| Bool`) instead of a whole set. Never touches any other local's
  ||| own ownership node (`reuseFrom` included) -- every case below only
  ||| ever inspects or rewrites `fid`'s own occurrences.
  reannotateFieldOwnership : (fid : Int) -> Bool -> RCExp -> (Bool, RCExp)
  reannotateFieldOwnership fid owned (RV fc v) =
      if v == RCLoc fid
         then if owned then (False, RV fc v) else (False, RDup fc v (RV fc v))
         else (owned, RV fc v)
  reannotateFieldOwnership fid owned (RAppName fc lazy n args) =
      let (nDups, owned') = countDupsNeeded fid owned args
      in (owned', wrapNDups fc fid nDups (RAppName fc lazy n args))
  reannotateFieldOwnership fid owned (RUnderApp fc n missing args) =
      let (nDups, owned') = countDupsNeeded fid owned args
      in (owned', wrapNDups fc fid nDups (RUnderApp fc n missing args))
  reannotateFieldOwnership fid owned (RApp fc lazy c a) =
      let (nDups, owned') = countDupsNeeded fid owned [c, a]
      in (owned', wrapNDups fc fid nDups (RApp fc lazy c a))
  reannotateFieldOwnership fid owned (RLet fc var rep value body) =
      -- Mirrors RC.idr's own annotate RLet case: whether `fid` is still
      -- needed in `body` (`usedInBody`, a `freeLocalsR` lookahead) is
      -- decided *before* `value` is processed, exactly like RC.idr's
      -- own `borrowVal`. This ordering is load-bearing, not cosmetic --
      -- getting it backwards (thread `value`'s own post-processing
      -- ownership into `body` unconditionally, an earlier version of
      -- this pass did exactly that) means whichever occurrence runs
      -- *first* gets the move and a later one gets the `dup` -- but a
      -- `dup` has to run *before* the object it protects could already
      -- be gone, not after: if the first (moved) use is the field's
      -- own last live reference and the callee it was moved into drops
      -- it once done, the second use's own `dup` would already be a
      -- use-after-free. Requiring `fid` still needed in `body` before
      -- ever treating `value`'s own use as a mere dup (never a move)
      -- guarantees the dup always runs first, ahead of any use that
      -- could free the object -- confirmed against exactly this shape
      -- via `tests/Test12ConAltNative.idr`'s own `multiBoxedUse` during
      -- development.
      --
      -- Note `usedInBody` is evaluated over `body` *after*
      -- `markNativeOccurrences` has already redirected every
      -- native-context occurrence of `fid` away from it -- exactly
      -- what's wanted here: only a genuinely surviving Boxed-context
      -- occurrence should count as "still needed", never one that's
      -- already been turned into a plain native read of the shadow.
      let usedInBody = contains (RCLoc fid) (freeLocalsR body)
          ownedForValue = owned && not usedInBody
          (ownedAfterValue, value') = reannotateFieldOwnership fid ownedForValue value
          -- If `body` doesn't need `fid` at all, thread `value`'s own
          -- actual result through rather than recomputing from `owned`
          -- (RC.idr's own `borrowVal` shape assumes `value` always
          -- resolves every occurrence it's handed, an assumption that
          -- doesn't hold here: `value` may contain zero occurrences of
          -- `fid` at all, e.g. an already-native-only sub-expression
          -- past `markNativeOccurrences`, in which case `owned` must
          -- pass through unchanged rather than being forced to `False`).
          ownedForBody = if usedInBody then owned else ownedAfterValue
          (ownedAfter, body') = reannotateFieldOwnership fid ownedForBody body
      in (ownedAfter, RLet fc var rep value' body')
  reannotateFieldOwnership fid owned (RCon fc n ci tag args reuseFrom) =
      let (nDups, owned') = countDupsNeeded fid owned args
      in (owned', wrapNDups fc fid nDups (RCon fc n ci tag args reuseFrom))
  reannotateFieldOwnership fid owned (ROp fc lazy op args postDrop) =
      -- Every occurrence needs its own drop once the op is done reading
      -- it, dup'd or moved-in alike (RC.idr's own `boxedOperands`
      -- doesn't consult ownership either, for the same reason).
      let argsList = toList args
          occ = length (filter (== RCLoc fid) argsList)
          (nDups, owned') = countDupsNeeded fid owned argsList
          postDrop' = postDrop ++ List.replicate occ (RCLoc fid)
      in (owned', wrapNDups fc fid nDups (ROp fc lazy op args postDrop'))
  -- Mirrors the ROp case immediately above exactly, primitive-agnostic
  -- (RC.idr's own annotate RExtPrim case now follows the same contract
  -- as ROp's own -- see doc/c-struct-support.md's "Why a dedicated
  -- node" section for the fixed-as-of gap this used to be a deliberate
  -- no-op for).
  reannotateFieldOwnership fid owned (RExtPrim fc lazy p args postDrop) =
      let occ = length (filter (== RCLoc fid) args)
          (nDups, owned') = countDupsNeeded fid owned args
          postDrop' = postDrop ++ List.replicate occ (RCLoc fid)
      in (owned', wrapNDups fc fid nDups (RExtPrim fc lazy p args postDrop'))
  reannotateFieldOwnership fid owned (RStructGet fc structVar sn fn postDrop) =
      let isField = structVar == RCLoc fid
          dropHere = isField && owned
          owned' = if isField then False else owned
          postDrop' = if dropHere then postDrop ++ [RCLoc fid] else postDrop
      in (owned', RStructGet fc structVar sn fn postDrop')
  reannotateFieldOwnership fid owned (RStructSet fc structVar sn fn value postDrop) =
      let scField = structVar == RCLoc fid
          valField = value == RCLoc fid
          dropSc = scField && owned
          owned1 = if scField then False else owned
          dropVal = valField && owned1
          owned2 = if valField then False else owned1
          postDrop' = postDrop ++ (if dropSc then [RCLoc fid] else [])
                               ++ (if dropVal then [RCLoc fid] else [])
      in (owned2, RStructSet fc structVar sn fn value postDrop')
  -- Every branch case below returns `False` (never `owned`/`owned'`)
  -- unconditionally, regardless of what `owned` was on entry:
  -- `finalizeBranch` leaves `fid` fully consumed on *every* arm it
  -- processes (either dropped, if the arm never touches it, or moved/
  -- dup'd away into whatever Boxed-context read it does find -- see its
  -- own doc comment), so by the time every arm has been rewritten,
  -- `fid` is provably spent no matter which arm control actually takes
  -- at runtime. Returning the pre-branch `owned`/`owned'` here instead
  -- (an earlier version of this pass did exactly that) is a real bug:
  -- a shadowAltFields caller wrapping this whole case in an unconditional
  -- outer `RDrop` (`needsDrop` still `True`) would double-drop `fid` on
  -- whichever arm `finalizeBranch` already dropped it in, and any
  -- caller-side Boxed-context use of `fid` genuinely reached *through*
  -- an arm that already moved/dropped it would be a use-after-free --
  -- confirmed with exactly this shape via `tests/Test12ConAltNative.idr`'s
  -- own `branchingUse` during development.
  reannotateFieldOwnership fid owned (RCmpCase fc op args postDrop t f) =
      -- markNativeOccurrences already redirected every native-context
      -- occurrence in `args` to the shadow id -- args is left untouched
      -- here (fid genuinely shouldn't still appear in it).
      (False, RCmpCase fc op args postDrop (finalizeBranch fid owned t) (finalizeBranch fid owned f))
  reannotateFieldOwnership fid owned (RConCase fc sc alts mDef) =
      let (nDups, owned') = countDupsNeeded fid owned [sc]
          alts' = map (\(MkRConAlt n ci tag as body) => MkRConAlt n ci tag as (finalizeBranch fid owned' body)) alts
          mDef' = map (finalizeBranch fid owned') mDef
      in (False, wrapNDups fc fid nDups (RConCase fc sc alts' mDef'))
  reannotateFieldOwnership fid owned (RConstCase fc sc alts mDef) =
      let (nDups, owned') = countDupsNeeded fid owned [sc]
          alts' = map (\(MkRConstAlt c body) => MkRConstAlt c (finalizeBranch fid owned' body)) alts
          mDef' = map (finalizeBranch fid owned') mDef
      in (False, wrapNDups fc fid nDups (RConstCase fc sc alts' mDef'))
  reannotateFieldOwnership fid owned (RDup fc v cont) =
      let (o, cont') = reannotateFieldOwnership fid owned cont in (o, RDup fc v cont')
  reannotateFieldOwnership fid owned (RDrop fc vs cont) =
      let (o, cont') = reannotateFieldOwnership fid owned cont in (o, RDrop fc vs cont')
  reannotateFieldOwnership fid owned (RFree fc v cont) =
      let (o, cont') = reannotateFieldOwnership fid owned cont in (o, RFree fc v cont')
  reannotateFieldOwnership fid owned (RReleaseReuse fc v cont) =
      let (o, cont') = reannotateFieldOwnership fid owned cont in (o, RReleaseReuse fc v cont')
  reannotateFieldOwnership fid owned (RReuseOffer fc sc dupOnShared dropOnUnique cont) =
      let (o, cont') = reannotateFieldOwnership fid owned cont in (o, RReuseOffer fc sc dupOnShared dropOnUnique cont')
  -- RPrimVal/RErased/RCrash carry no locals; RLoop/RLoopContinue/
  -- RAppNameRep never appear here in practice (this pass runs strictly
  -- before Compiler.RC2.Loop/MutualLoop/DualABI ever produce one, same
  -- reasoning as applyConAltNativeExp's own catch-all below).
  reannotateFieldOwnership _ owned e = (owned, e)

  ||| Process one branch arm independently from the pre-branch `owned`
  ||| state: rebuild ownership for just this arm via
  ||| `reannotateFieldOwnership`, then drop `fid` right at the arm's own
  ||| entry if it comes back still un-consumed (mirrors `RC.idr`'s own
  ||| `branchBody`) -- an *after-the-fact* check on `reannotateFieldOwnership`'s
  ||| own result, not a `freeLocalsR` lookahead over `body` (which, like
  ||| the `RLet` case above, can no longer see a native-context
  ||| occurrence `markNativeOccurrences` already redirected away, and
  ||| would otherwise conclude -- wrongly -- that a still-live shadowed
  ||| field needs dropping here). Each arm is independent -- one arm
  ||| consuming `fid` and another not touching it at all is the exact
  ||| asymmetric case this exists to handle correctly.
  finalizeBranch : (fid : Int) -> Bool -> RCExp -> RCExp
  finalizeBranch fid owned body =
      let (ownedAfter, body') = reannotateFieldOwnership fid owned body
      in if ownedAfter then RDrop emptyFC [RCLoc fid] body' else body'

||| Promote whichever of `argIds` (one alt's own destructured fields)
||| `nativeArgType` finds read as a native-context operand somewhere in
||| this alt's own "core" (past every leading ownership/reuse wrapper,
||| see `peelWrappers`), consistently -- same eligibility question,
||| same `assignShadowIds` shape as `Compiler.RC2.Loop`'s own
||| `applyLoop`. Wraps `core` (never the wrappers `peelWrappers` already
||| split off -- those stay completely untouched, not even renamed
||| into, so a reuse decision already made there is never disturbed) in
||| one `RLet` per promoted field: the `RLet` reads the original (still
||| fully Boxed, still fully owned) field exactly once, natively, into
||| the fresh shadow. What happens next depends on whether the field is
||| *also* read in a Boxed context somewhere in `core`: if not, the
||| shadow read is followed by an unconditional `RDrop` releasing the
||| original (provably dead within `core`, every other reference having
||| just been redirected to the shadow) -- the original, simpler
||| behaviour. If it *is* also read Boxed, the original field id is
||| left alone at those Boxed-context sites (`markNativeOccurrences`
||| only ever redirects the native-context ones) and its own ownership
||| there is rebuilt from scratch (`reannotateFieldOwnership`) rather
||| than reboxing fresh at every such site -- see TODO.md's own
||| "Performance: reboxing a native-shadowed value always allocates
||| fresh" entry for the motivation.
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
                  wrappedCore : RCExp
                  wrappedCore = foldr shadowOneField core shadowed
              in (nextId + cast (length eligible), rebuild wrappedCore)
  where
    ||| Wrap `acc` with `p`'s own shadow `RLet`, having first cleared
    ||| `p`'s own stale ownership bookkeeping (`stripOwnership`, keyed
    ||| on `p` alone rather than on a shadow-id set the way the old
    ||| combined pass used to), redirected its native-context
    ||| occurrences to `sid` (`markNativeOccurrences`), and rebuilt
    ||| ownership for whatever Boxed-context occurrences remain
    ||| (`reannotateFieldOwnership`, starting from `p` fully owned --
    ||| exactly true here, since `core` is the point past every leading
    ||| wrapper and `p` is one of this alt's own destructured fields).
    shadowOneField : (Int, Int, PrimType) -> RCExp -> RCExp
    shadowOneField (p, sid, ty) acc =
        let stripped = stripOwnership (SortedSet.singleton p) acc
            marked = markNativeOccurrences p sid stripped
            (needsDrop, reAnnotated) = reannotateFieldOwnership p True marked
        in RLet emptyFC sid (RNative ty) (RV emptyFC (RCLoc p))
             (if needsDrop then RDrop emptyFC [RCLoc p] reAnnotated else reAnnotated)

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
  applyConAltNativeExp nextId (RReuseOffer fc sc dupOnShared dropOnUnique body) =
      let (n, body') = applyConAltNativeExp nextId body in (n, RReuseOffer fc sc dupOnShared dropOnUnique body')
  -- Every other shape (RV, RAppName, RUnderApp, RApp, RCon, ROp,
  -- RExtPrim, RPrimVal, RErased, RCrash, RLoopContinue, RAppNameRep,
  -- RStructGet, RStructSet -- and RLoop, though this pass runs
  -- strictly before Compiler.RC2.Loop/MutualLoop ever produce one, see
  -- RC2.idr's own toRCDefs): no further RCExp to recurse into.
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
applyConAltNative (MkRCFun args retRep isWorker body) =
    let argIds = map fst args
        nextId = the Int (1 + foldl max (-1) (argIds ++ collectBoundIds body))
        (_, body') = applyConAltNativeExp nextId body
    in MkRCFun args retRep isWorker body'
applyConAltNative (MkRCError body) =
    let nextId = the Int (1 + foldl max (-1) (collectBoundIds body))
        (_, body') = applyConAltNativeExp nextId body
    in MkRCError body'
applyConAltNative d@(MkRCCon _ _ _) = d
applyConAltNative d@(MkRCForeign _ _ _) = d
