module Compiler.RC2.ConAltNative

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Caches a constructor-destructured field, read as a native operand
-- more than once, into a fresh native shadow instead of re-unboxing it
-- at every read. Never touches the field's own Boxed declaration or
-- its ownership decisions from `Compiler.RC2.RC`'s `annotate`/
-- `Compiler.RC2.Reuse`'s `resolveAlt` -- runs strictly after both (see
-- `RC2.idr`'s own `toRCDefs`) and only ever *adds* a wrapping
-- `RLet`+`RDrop` around the alt's own "core" (past any leading
-- ownership/reuse wrapper -- see `peelWrappers`). A field also read in
-- a genuinely separate Boxed context keeps that reference on the
-- original field id, sharing its identity via an ordinary dup/move
-- rather than reboxing the shadow fresh each time. See
-- `doc/con-alt-native.md` for the full design, algorithm, and bug
-- history.

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
||| `RReuseOffer` node off an alt's own body, returning a rebuilding
||| function alongside the "core" underneath -- the only safe point to
||| insert a native shadow read, since inserting earlier runs ahead of
||| `Compiler.RC2.Reuse`'s own uniqueness check. See
||| `doc/con-alt-native.md`'s "Core: peeling..." section and "Bugs
||| found and fixed" #2 for the leak this fixes.
peelWrappers : RCExp -> (RCExp -> RCExp, RCExp)
peelWrappers (RDup fc v extra cont) =
    let (rebuild, core) = peelWrappers cont in (\c => RDup fc v extra (rebuild c), core)
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
-- Reusing the original Boxed field for a surviving Boxed-context read,
-- instead of reboxing fresh. See `doc/con-alt-native.md`'s "Reusing
-- the original Boxed field for surviving Boxed-context reads".

||| Mirrors `Loop.idr`'s own `opNativeUsesThrough` walk, but rewrites
||| instead of collecting: once inside the `ROp` a native-`Rep` `RLet`'s
||| own `value` peels down to, redirect `fid`'s own occurrences in its
||| `args` to `sid`.
renameOpArgsThrough : (fid : Int) -> (sid : Int) -> RCExp -> RCExp
renameOpArgsThrough fid sid (ROp fc lazy op args postDrop) =
    ROp fc lazy op (map (\a => if a == RCLoc fid then RCLoc sid else a) args) postDrop
renameOpArgsThrough fid sid (RDup fc v extra cont) = RDup fc v extra (renameOpArgsThrough fid sid cont)
renameOpArgsThrough fid sid (RDrop fc vs cont) = RDrop fc vs (renameOpArgsThrough fid sid cont)
renameOpArgsThrough fid sid (RFree fc v cont) = RFree fc v (renameOpArgsThrough fid sid cont)
renameOpArgsThrough fid sid (RReleaseReuse fc v cont) = RReleaseReuse fc v (renameOpArgsThrough fid sid cont)
renameOpArgsThrough fid sid (RLet fc var rep value body) = RLet fc var rep value (renameOpArgsThrough fid sid body)
renameOpArgsThrough _ _ e = e

||| Mirrors `Loop.idr`'s own `nativeArgTypes` walk exactly, but rewrites
||| the native-context occurrences it finds instead of collecting their
||| types. Every Boxed-context occurrence of `fid` is left untouched
||| here -- `reannotateFieldOwnership` handles those next.
markNativeOccurrences : (fid : Int) -> (sid : Int) -> RCExp -> RCExp
markNativeOccurrences fid sid (RLet fc var rep value body) =
    let value' = case rep of
                      RBoxed => value
                      _ => renameOpArgsThrough fid sid value
    in RLet fc var rep (markNativeOccurrences fid sid value') (markNativeOccurrences fid sid body)
markNativeOccurrences fid sid (RCmpCase fc op args postDrop t f) =
    RCmpCase fc op (map (\a => if a == RCLoc fid then RCLoc sid else a) args) postDrop
             (markNativeOccurrences fid sid t) (markNativeOccurrences fid sid f)
markNativeOccurrences fid sid (RDup fc v extra cont) = RDup fc v extra (markNativeOccurrences fid sid cont)
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

||| How many `RDup`s an operand list needs for `fid`'s occurrences in
||| it: one per occurrence past the first if `fid` is still `owned`
||| (the first occurrence moves); every occurrence needs one if `fid`
||| is already spent. Same rule as `RC.idr`'s own `splitBorrows`,
||| specialised to a single local. Returns updated ownership alongside
||| the count.
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
wrapNDups fc fid (S k) e = RDup fc (RCLoc fid) 0 (wrapNDups fc fid k e)

-- `reannotateFieldOwnership`/`finalizeBranch` are mutually recursive
-- (three of `reannotateFieldOwnership`'s own case clauses call
-- `finalizeBranch`, which calls back into it) -- forward-declared here
-- to avoid a `mutual` block, the same technique `RCExp.idr` uses for
-- its own `RCLocal`/`IsAnyConstLocal`.
|||
||| Process one branch arm independently: rebuild ownership via
||| `reannotateFieldOwnership`, then drop `fid` if it comes back still
||| un-consumed (mirrors `RC.idr`'s own `branchBody`). Checks
||| `reannotateFieldOwnership`'s own result *after the fact*, not a
||| `freeLocalsR` lookahead -- that can no longer see a native-context
||| occurrence already redirected away, and would wrongly conclude a
||| still-live shadowed field needs dropping. See
||| `doc/con-alt-native.md`'s "Reusing the original Boxed field..."
||| section, bug #2.
finalizeBranch : (fid : Int) -> Bool -> RCExp -> RCExp

||| Rebuild ownership for exactly `fid`, from scratch, over a body
||| whose every remaining occurrence is a genuine Boxed-context read
||| (native-context ones were already redirected by
||| `markNativeOccurrences`, stale bookkeeping already cleared by
||| `stripOwnership`). Same "first occurrence moves, later ones dup"
||| rule as `RC.idr`'s own `annotate`/`splitBorrows`/`branchBody`,
||| specialised to a single local (`owned : Bool`). Never touches any
||| other local's own ownership node.
reannotateFieldOwnership : (fid : Int) -> Bool -> RCExp -> (Bool, RCExp)
reannotateFieldOwnership fid owned (RV fc v) =
    if v == RCLoc fid
       then if owned then (False, RV fc v) else (False, RDup fc v 0 (RV fc v))
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
    -- Mirrors RC.idr's own `annotate`/`borrowVal`: whether `fid` is
    -- still needed in `body` is decided *before* `value` is processed,
    -- so a protecting `dup` always runs ahead of any use that could
    -- free the object -- getting this backwards caused a real
    -- leak/use-after-free, see `doc/con-alt-native.md`'s "Reusing the
    -- original Boxed field..." section, bug #1. `usedInBody` is
    -- checked against `body` *after* `markNativeOccurrences` already
    -- redirected native occurrences away, so it only ever means
    -- "genuinely still read Boxed".
    let usedInBody = contains (RCLoc fid) (freeLocalsR body)
        ownedForValue = owned && not usedInBody
        (ownedAfterValue, value') = reannotateFieldOwnership fid ownedForValue value
        -- If `body` doesn't need `fid`, thread `value`'s own result
        -- through rather than recomputing from `owned` -- unlike
        -- RC.idr's own `borrowVal`, `value` here can resolve zero
        -- occurrences of `fid` at all.
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
-- Mirrors the ROp case above exactly, primitive-agnostic -- see
-- doc/c-struct-support.md's "Why a dedicated node".
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
-- Every branch case below returns `False` unconditionally --
-- `finalizeBranch` leaves `fid` fully consumed on every arm it
-- processes, so it's provably spent regardless of which arm runs.
-- Returning the pre-branch `owned` here instead was a real bug
-- (double-drop + use-after-free) -- see `doc/con-alt-native.md`'s
-- "Reusing the original Boxed field..." section, bug #2.
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
reannotateFieldOwnership fid owned (RDup fc v extra cont) =
    let (o, cont') = reannotateFieldOwnership fid owned cont in (o, RDup fc v extra cont')
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

finalizeBranch fid owned body =
    let (ownedAfter, body') = reannotateFieldOwnership fid owned body
    in if ownedAfter then RDrop emptyFC [RCLoc fid] body' else body'

||| Promote whichever of `argIds` (one alt's own destructured fields)
||| `nativeArgType` finds read as a native-context operand, somewhere
||| in this alt's own "core" (past every leading wrapper, see
||| `peelWrappers`) -- same eligibility question as
||| `Compiler.RC2.Loop`'s own `applyLoop`. Wraps `core` in one `RLet`
||| per promoted field, reading the original field natively into a
||| fresh shadow; a field with no surviving Boxed-context use gets an
||| unconditional `RDrop` right after, otherwise its remaining
||| Boxed-context ownership is rebuilt from scratch instead of
||| reboxing fresh each time. See `doc/con-alt-native.md`'s "Design"
||| section.
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
    ||| Wrap `acc` with `p`'s own shadow `RLet`: clear `p`'s stale
    ||| ownership (`stripOwnership`), redirect native-context
    ||| occurrences to `sid` (`markNativeOccurrences`), then rebuild
    ||| ownership for whatever Boxed-context occurrences remain
    ||| (`reannotateFieldOwnership`, starting fully owned -- true here
    ||| since `core` is past every leading wrapper).
    shadowOneField : (Int, Int, PrimType) -> RCExp -> RCExp
    shadowOneField (p, sid, ty) acc =
        let stripped = stripOwnership (SortedSet.singleton p) acc
            marked = markNativeOccurrences p sid stripped
            (needsDrop, reAnnotated) = reannotateFieldOwnership p True marked
        in RLet emptyFC sid (RNative ty) (RV emptyFC (RCLoc p))
             (if needsDrop then RDrop emptyFC [RCLoc p] reAnnotated else reAnnotated)

||| Walks the whole tree (an `RConCase` can appear anywhere, not just
||| tail position), threading a single fresh-id counter so every
||| promoted field gets its own distinct shadow id -- same style
||| `Compiler.RC2.Loop`'s own `applyLoop` uses for its own
||| (function-scoped) shadow ids.
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
    let (nextId1, alts') = goAlts nextId alts
        (nextId2, mDef') = goMaybe nextId1 mDef
    in (nextId2, RConCase fc sc alts' mDef')
  where
    -- Recurse into this alt's own body first (promoting any more
    -- deeply nested alt's own fields), then promote this alt's own
    -- fields -- the two are independent (disjoint id namespaces,
    -- `nativeArgType`'s own scan only ever looks for a *specific* id's
    -- own uses), so the order between them only affects which shadow
    -- ids end up numerically first.
    goAlt : Int -> RConAlt -> (Int, RConAlt)
    goAlt n (MkRConAlt name ci tag args body) =
        let (n1, body1) = applyConAltNativeExp n body
            (n2, body2) = shadowAltFields n1 args body1
        in (n2, MkRConAlt name ci tag args body2)
    goAlts : Int -> List RConAlt -> (Int, List RConAlt)
    goAlts n [] = (n, [])
    goAlts n (a :: rest) =
        let (n1, a') = goAlt n a
            (n2, rest') = goAlts n1 rest
        in (n2, a' :: rest')
    goMaybe : Int -> Maybe RCExp -> (Int, Maybe RCExp)
    goMaybe n Nothing = (n, Nothing)
    goMaybe n (Just e) = let (n', e') = applyConAltNativeExp n e in (n', Just e')
applyConAltNativeExp nextId (RConstCase fc sc alts mDef) =
    let (nextId1, alts') = goAlts nextId alts
        (nextId2, mDef') = goMaybe nextId1 mDef
    in (nextId2, RConstCase fc sc alts' mDef')
  where
    goAlts : Int -> List RConstAlt -> (Int, List RConstAlt)
    goAlts n [] = (n, [])
    goAlts n (MkRConstAlt c body :: rest) =
        let (n1, body') = applyConAltNativeExp n body
            (n2, rest') = goAlts n1 rest
        in (n2, MkRConstAlt c body' :: rest')
    goMaybe : Int -> Maybe RCExp -> (Int, Maybe RCExp)
    goMaybe n Nothing = (n, Nothing)
    goMaybe n (Just e) = let (n', e') = applyConAltNativeExp n e in (n', Just e')
applyConAltNativeExp nextId (RDup fc v extra body) =
    let (n, body') = applyConAltNativeExp nextId body in (n, RDup fc v extra body')
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
-- RStructGet, RStructSet -- and RLoop, though this pass runs strictly
-- before Compiler.RC2.Loop/MutualLoop ever produce one, see RC2.idr's
-- own toRCDefs): no further RCExp to recurse into.
applyConAltNativeExp nextId e = (nextId, e)

||| Apply constructor-destructured-field native shadowing to one
||| top-level definition. Fresh shadow ids start one past the highest
||| id already used anywhere in the definition (own top-level `args`,
||| plus every `RLet`/`RConAlt`-bound id in `body`, via
||| `Compiler.RC2.Loop`'s own `collectBoundIds`) -- same reasoning
||| `applyLoop` already uses for its own shadow ids: a plain arithmetic
||| maximum is enough since this pass is a pure function of one
||| definition at a time, no cross-definition state needed.
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
