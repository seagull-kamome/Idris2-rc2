module Compiler.RC2.Sink

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Branch-local sinking: moves a `let`-bound value into every branch
-- arm that actually reads it (duplicating it there if more than one
-- does), dropping it everywhere else instead of computing it
-- unconditionally. Deliberately its own pass, not folded into
-- `Compiler.RC2.Loop` -- see `rc2/doc/branch-sinking.md` for the full
-- design rationale, algorithm, and bug history.

import Compiler.RC2.RCExp
import Compiler.RC2.Types
import Compiler.RC2.Util

import Core.CompileExpr
import Core.FC
import Core.TT

import Data.List
import Data.SortedMap
import Data.SortedSet
import Data.Vect

%default covering

------------------------------------------------------------------------
-- Which locals a branch genuinely *reads* (see doc/branch-sinking.md's
-- "Classifying each arm" for why this differs from RCExp.idr's own
-- `freeLocalsR`).

||| Every `RCLocal` genuinely read anywhere in `e` -- like
||| `freeLocalsR`, but an `RDrop`/`RFree`/`RReleaseReuse` target is not
||| a "use" (see the section note above). Covers `RLoop`/
||| `RLoopContinue` since this pass runs after `Compiler.RC2.Loop` --
||| see doc/branch-sinking.md's "Pipeline position".
genuinelyUsedR : RCExp -> SortedSet RCLocal
genuinelyUsedR (RV _ v) = singleton v
genuinelyUsedR (RAppName _ _ _ args) = fromList args
genuinelyUsedR (RUnderApp _ _ _ args) = fromList args
genuinelyUsedR (RApp _ _ c args) = fromList (c :: args)
genuinelyUsedR (RAppNameRep _ _ _ _ _ args) = fromList args
genuinelyUsedR (RLet _ var _ value body) =
    union (genuinelyUsedR value) (delete (RCLoc var) (genuinelyUsedR body))
genuinelyUsedR (RCon _ _ _ _ args _) = fromList args
genuinelyUsedR (ROp _ _ _ args _) = fromList (toList args)
genuinelyUsedR (RExtPrim _ _ _ args _) = fromList args
genuinelyUsedR (RStructGet _ structVar _ _ _) = singleton structVar
genuinelyUsedR (RStructSet _ structVar _ _ value _) = fromList [structVar, value]
genuinelyUsedR (RFill _ cell _ value _) = fromList [cell, value]
genuinelyUsedR (RCmpCase _ _ args _ t f) =
    union (fromList (toList args)) (union (genuinelyUsedR t) (genuinelyUsedR f))
genuinelyUsedR (RConCase _ sc alts mDef) =
    let altsUsed = map (\(MkRConAlt _ _ _ as body) =>
                          difference (genuinelyUsedR body) (fromList (map RCLoc as))) alts
        allUsed = maybe altsUsed (\d => genuinelyUsedR d :: altsUsed) mDef
    in insert sc (concat allUsed)
genuinelyUsedR (RConstCase _ sc alts mDef) =
    let altsUsed = map (\(MkRConstAlt _ body) => genuinelyUsedR body) alts
        allUsed = maybe altsUsed (\d => genuinelyUsedR d :: altsUsed) mDef
    in insert sc (concat allUsed)
genuinelyUsedR (RDup _ v _ body) = insert v (genuinelyUsedR body)
genuinelyUsedR (RDrop _ _ body) = genuinelyUsedR body
genuinelyUsedR (RFree _ _ body) = genuinelyUsedR body
genuinelyUsedR (RReleaseReuse _ _ body) = genuinelyUsedR body
genuinelyUsedR (RReuseOffer _ sc dupOnShared dropOnUnique body) =
    union (insert sc (fromList dupOnShared `union` fromList dropOnUnique)) (genuinelyUsedR body)
genuinelyUsedR (RLoop _ _ initial _ body) = union (fromList initial) (genuinelyUsedR body)
genuinelyUsedR (RLoopContinue _ args postDrop) = union (fromList args) (fromList postDrop)
genuinelyUsedR _ = empty

||| Strips every occurrence of `var` from any `RDrop`'s own `vars` list
||| anywhere in `e` (removing the whole node if that empties it) --
||| only called once `genuinelyUsedR` confirms `var` is never read in
||| `e`. Walks the *whole* tree rather than just a leading-wrapper peel
||| -- this pass runs after both `Compiler.RC2.Reuse` and
||| `Compiler.RC2.Loop`, unlike e.g. `Compiler.RC2.ConAltNative`'s
||| shallower `peelWrappers` -- see doc/branch-sinking.md's "The
||| rewrite itself".
removeVarDrop : Int -> RCExp -> RCExp
removeVarDrop var (RLet fc v rep value body) = RLet fc v rep value (removeVarDrop var body)
removeVarDrop var (RDup fc v extra body) = RDup fc v extra (removeVarDrop var body)
removeVarDrop var (RDrop fc vars body) =
    let vars' = filter (/= RCLoc var) vars
        body' = removeVarDrop var body
    in if null vars' then body' else RDrop fc vars' body'
removeVarDrop var (RFree fc v body) = RFree fc v (removeVarDrop var body)
removeVarDrop var (RReleaseReuse fc v body) = RReleaseReuse fc v (removeVarDrop var body)
removeVarDrop var (RReuseOffer fc sc dupOnShared dropOnUnique body) = RReuseOffer fc sc dupOnShared dropOnUnique (removeVarDrop var body)
removeVarDrop var (RCmpCase fc op args pd t f) = RCmpCase fc op args pd (removeVarDrop var t) (removeVarDrop var f)
removeVarDrop var (RConCase fc sc alts mDef) =
    RConCase fc sc (map (\(MkRConAlt n ci tag as body) => MkRConAlt n ci tag as (removeVarDrop var body)) alts)
      (map (removeVarDrop var) mDef)
removeVarDrop var (RConstCase fc sc alts mDef) =
    RConstCase fc sc (map (\(MkRConstAlt c body) => MkRConstAlt c (removeVarDrop var body)) alts)
      (map (removeVarDrop var) mDef)
removeVarDrop var (RLoop fc loopParams initial prologueDrop body) =
    RLoop fc loopParams initial prologueDrop (removeVarDrop var body)
removeVarDrop _ e = e

||| `Nothing` if `var` is genuinely read anywhere in `branch` (a
||| candidate for the *one* arm `value` sinks into); `Just` the
||| rewritten branch (its own stale `drop [var, ...]`, if any, stripped
||| -- unchanged otherwise) if `var` is never genuinely read there at
||| all.
stripIfUnused : Int -> RCExp -> Maybe RCExp
stripIfUnused var branch =
    if contains (RCLoc var) (genuinelyUsedR branch)
       then Nothing
       else Just (removeVarDrop var branch)

||| Every Boxed operand `value` itself *consumes* by reading it -- an
||| `ROp`'s or `RStructGet`'s own `postDrop` (both populated the same
||| way, by `Compiler.RC2.RC`'s own `dropIfLastUse` -- see
||| `rc2/doc/c-struct-support.md`'s own "ownership" section for why a
||| struct pointer's read needs exactly `ROp`'s drop treatment despite
||| having no operands of its own to `dup`), an `RAppName`'s Boxed args
||| (filtered via `reps`, since a call unconditionally consumes *all*
||| its args), or (tracked via `dupped`) any `RCon` field *not* `dup`'d
||| first. These
||| need an explicit `drop` in every arm `value` doesn't sink into,
||| replacing the release `value`'s own `postDrop`/field-move used to
||| unconditionally provide -- see doc/branch-sinking.md's "The rewrite
||| itself, and the second real bug it took to get right" (the
||| `getAt` leak this fixes).
|||
||| Restricted to `RCLoc` operands even where `localRepIn` alone would
||| call a constant `RBoxed` too (`RCEmptyCon`/`RCConstCon`/
||| `RCConstClosure` always, `RCConst` whenever `litRep` can't place it
||| natively) -- none of `RCLocal`'s constant-shaped constructors is
||| ever a real refcounted value with a matching `drop` to balance;
||| `Compiler.RC2.Emit.Util`'s own `varName` has no rendering for one at
||| all (an "unreachable" placeholder), which is exactly what a
||| constant field of a sunk `RCon` used to reach here once
||| `Compiler.RC2.LateInline`'s own splice stopped wrapping *every*
||| argument in its own fresh `RLet` first.
consumedOperands : SortedMap Int Rep -> RCExp -> List RCLocal
consumedOperands reps = go []
  where
    isDroppableBoxed : RCLocal -> Bool
    isDroppableBoxed a@(RCLoc _) = case localRepIn reps a of
                                         RBoxed => True
                                         _ => False
    isDroppableBoxed _ = False
    go : List RCLocal -> RCExp -> List RCLocal
    -- Same `dupped` exclusion as the RCon case below: a postDrop target
    -- `value` itself already `dup`'d earlier in this same chain is
    -- self-contained, not something the branch we don't sink into owes
    -- a compensating drop for.
    go dupped (ROp _ _ _ _ postDrop) = filter (\a => not (a `elem` dupped)) postDrop
    go dupped (RStructGet _ _ _ _ postDrop) = filter (\a => not (a `elem` dupped)) postDrop
    go _ (RAppName _ _ _ args) = filter isDroppableBoxed args
    go dupped (RCon _ _ _ _ args _) = filter (\a => isDroppableBoxed a && not (a `elem` dupped)) args
    go dupped (RDup _ v _ cont) = go (v :: dupped) cont
    go dupped (RDrop _ _ cont) = go dupped cont
    go dupped (RFree _ _ cont) = go dupped cont
    go dupped (RReleaseReuse _ _ cont) = go dupped cont
    go _ _ = []

||| Every local that already appears in some `RDrop` anywhere within
||| `e` -- `addOperandDrops` (below) needs this alongside
||| `genuinelyUsedR` to recognise an operand `branch` already owes a
||| drop for on its own (an RC-annotation-phase `drop` that predates
||| this sink, or one an *earlier* sink operation on a different `let`
||| already prepended to this same branch), not just one it still
||| reads. `genuinelyUsedR` alone can't see this: it deliberately
||| treats an `RDrop`'s own targets as not "read" (see that function's
||| own doc comment), so a second `addOperandDrops` call for a
||| *different* sunk `let` that happens to share an operand with the
||| first would sail straight past that guard and stack a second,
||| redundant `drop` for the same local on top -- a real double-drop
||| this pass produced from real idris2-lsp source (`Core.Normalise.
||| Eval.evalRef`'s own `evalOp` case block), caught by `rcexpr-lint`.
||| Same traversal shape as `genuinelyUsedR` itself, so the two agree
||| on every place a `RDrop` can turn up.
alreadyDropped : RCExp -> SortedSet RCLocal
alreadyDropped (RLet _ _ _ value body) = union (alreadyDropped value) (alreadyDropped body)
alreadyDropped (RDrop _ vars body) = union (fromList vars) (alreadyDropped body)
alreadyDropped (RDup _ _ _ body) = alreadyDropped body
alreadyDropped (RFree _ _ body) = alreadyDropped body
alreadyDropped (RReleaseReuse _ _ body) = alreadyDropped body
alreadyDropped (RReuseOffer _ _ _ _ body) = alreadyDropped body
alreadyDropped (RCmpCase _ _ _ _ t f) = union (alreadyDropped t) (alreadyDropped f)
alreadyDropped (RConCase _ _ alts mDef) =
    let altsD = map (\(MkRConAlt _ _ _ _ body) => alreadyDropped body) alts
    in concat (maybe altsD (\d => alreadyDropped d :: altsD) mDef)
alreadyDropped (RConstCase _ _ alts mDef) =
    let altsD = map (\(MkRConstAlt _ body) => alreadyDropped body) alts
    in concat (maybe altsD (\d => alreadyDropped d :: altsD) mDef)
alreadyDropped (RLoop _ _ _ _ body) = alreadyDropped body
alreadyDropped _ = empty

||| Prefixes `branch` (already `var`-stripped by `stripIfUnused`) with
||| a `drop` for every one of `consumed` -- see `consumedOperands`'s
||| own doc comment. `Nothing` (fall back to not sinking) if one of
||| them is already read in `branch` (would risk a double-drop) *or*
||| already appears in some `RDrop` already present in `branch`
||| (`alreadyDropped`, above -- would risk stacking a second, redundant
||| drop on top of one `branch` already owes) -- both vanishingly
||| unlikely, costs nothing to guard against either. `Just branch`
||| unchanged when `consumed` is empty (the overwhelming common case).
addOperandDrops : FC -> List RCLocal -> RCExp -> Maybe RCExp
addOperandDrops _ [] branch = Just branch
addOperandDrops fc consumed branch =
    if any (\op => contains op (genuinelyUsedR branch) || contains op (alreadyDropped branch)) consumed
       then Nothing
       else Just (RDrop fc consumed branch)

------------------------------------------------------------------------
-- Deciding whether `value` itself is even a candidate to sink at all.

||| Whether `value` (after peeling the same leading `RDup`/`RDrop`/
||| `RFree`/`RReleaseReuse` wrappers `Compiler.RC2.Loop`'s own
||| `isInvariantExpr` peels for an analogous reason) is a bare
||| `ROp`/`RCon`/`RAppName`/`RStructGet` eligible to sink -- same
||| exclusions as `isInvariantExpr` for the first three (non-`Lazy`, no
||| `reuseFrom`), kept in sync deliberately rather than re-derived.
||| Unlike hoisting, `RAppName` *is* eligible here: sinking only ever
||| reduces how many times a call runs, never turns a skipped call into
||| one that runs. `RStructGet` needs no such guard at all -- it has
||| neither a `lazy` nor a `reuseFrom` field to exclude on, a struct
||| field read being unconditionally eager and never itself a reuse
||| candidate -- but its own `postDrop` still needs `consumedOperands`
||| (above) to compensate for, exactly like `ROp`'s. `RApp`/
||| `RUnderApp`/`RExtPrim` stay out of scope. See
||| doc/branch-sinking.md's "Deciding whether value is even a
||| candidate".
sinkEligible : RCExp -> Bool
sinkEligible (ROp _ Nothing _ _ _) = True
sinkEligible (RCon _ _ _ _ _ Nothing) = True
sinkEligible (RAppName _ Nothing _ _) = True
sinkEligible (RStructGet _ _ _ _ _) = True
sinkEligible (RDup _ _ _ cont) = sinkEligible cont
sinkEligible (RDrop _ _ cont) = sinkEligible cont
sinkEligible (RFree _ _ cont) = sinkEligible cont
sinkEligible (RReleaseReuse _ _ cont) = sinkEligible cont
sinkEligible _ = False

------------------------------------------------------------------------
-- The rewrite itself, per branch-node shape.

||| Whether `var` is itself one of the operands deciding which arm
||| runs -- an `RCmpCase`'s own comparison args, or an `RConCase`/
||| `RConstCase`'s own scrutinee. These are evaluated before any arm
||| runs, so sinking into one specific arm is structurally impossible
||| for them. See doc/branch-sinking.md's "`var` must not be the
||| branch's own deciding operand" (the `fib` miscompile this guards
||| against). `trySinkInto` checks this before ever calling
||| `trySinkIntoArms` below.
||| Also true if `value` itself (not just `var`, the name it would be
||| bound to) reads a deciding operand: that operand's own last owned
||| reference may be spent by evaluating the branch condition, so
||| moving `value`'s own read of it to after that point is just as
||| unsafe as `var` being the deciding operand outright.
isDecidingOperand : Int -> RCExp -> RCExp -> Bool
isDecidingOperand var value branch =
    let candidates = insert (RCLoc var) (genuinelyUsedR value)
        deciders = case branch of
                        RCmpCase _ _ args _ _ _ => fromList (toList args)
                        RConCase _ sc _ _ => singleton sc
                        RConstCase _ sc _ _ => singleton sc
                        _ => empty
    in not (null (intersection candidates deciders))

||| Classifies one single arm of `branch` for sinking `RLet _ var rep
||| value _`'s own binding: `Nothing` if `var` is genuinely read there
||| (this arm stays exactly as-is -- the caller re-wraps it in the
||| original `RLet`, see `sinkIntoBodies`'s/`trySinkIntoArms`'s own
||| `pick`), `Just` the rewritten arm (its own stale `drop [var, ...]`
||| stripped via `stripIfUnused`, plus a compensating `drop` for
||| `value`'s own `consumedOperands`, once `stripIfUnused` confirms
||| `var` unused there -- folding both fixes into one so every call
||| site below gets the leak fix for free) if `var` is never read at
||| all. The caller decides, from how many arms come back `Nothing` vs.
||| `Just`, whether sinking into all the `Nothing` arms is even
||| worthwhile as a whole (see `sinkIntoBodies`'s own doc comment).
||| `fc` is the *enclosing branch node's* own `FC`, needed since a
||| fresh `RDrop` needs one of its own and an arm's body isn't
||| necessarily a branch node to borrow one from.
stripForSink : Int -> FC -> List RCLocal -> RCExp -> Maybe RCExp
stripForSink var fc consumed branch = stripIfUnused var branch >>= addOperandDrops fc consumed

||| `stripForSink` over every alt body plus the optional default body
||| of an `RConCase`/`RConstCase` -- shared since the two differ only
||| in alt shape (`MkRConAlt` vs `MkRConstAlt`), not in this logic.
|||
||| Sinks into *every* Used body at once (duplicating `value`'s own
||| computation into each one via `pick`'s fallback), not just a single
||| one -- unlike hoisting, this costs nothing at runtime: exactly one
||| arm ever runs per evaluation, so a value duplicated into N Used arms
||| still computes at most once per evaluation either way, the same as
||| it would sitting unconditionally before the whole branch. The only
||| real cost is code size, and `sinkEligible` already bounds `value` to
||| a single bare `ROp`/`RCon`/`RAppName`/`RStructGet` node, never an
||| arbitrarily large subtree, so that cost stays modest. `Nothing` in
||| exactly two cases: `usedCount == 0` (nothing to sink, `value` would
||| just vanish) or `usedCount == totalCount` (Used everywhere -- every
||| arm already needs it unconditionally, so duplicating buys nothing
||| and only bloats code size; leaving the original, single, pre-branch
||| computation in place is strictly better). See
||| doc/branch-sinking.md's "The rewrite itself" for the fuller
||| rationale (formerly "exactly one arm", generalised here).
sinkIntoBodies : FC -> Int -> Rep -> RCExp -> List RCLocal -> List RCExp -> Maybe RCExp -> Maybe (List RCExp, Maybe RCExp)
sinkIntoBodies fc var rep value consumed altBodies mDefBody =
    let altStripped : List (RCExp, Maybe RCExp)
        altStripped = map (\body => (body, stripForSink var fc consumed body)) altBodies
        defStripped : Maybe (RCExp, Maybe RCExp)
        defStripped = map (\d => (d, stripForSink var fc consumed d)) mDefBody
        defResults : List (Maybe RCExp)
        defResults = case defStripped of
                          Nothing => []
                          Just (_, r) => [r]
        allResults : List (Maybe RCExp)
        allResults = map snd altStripped ++ defResults
        usedCount : Nat
        usedCount = length (filter isNothing allResults)
        totalCount : Nat
        totalCount = length allResults
        pick : (RCExp, Maybe RCExp) -> RCExp
        pick (orig, r) = fromMaybe (RLet fc var rep value orig) r
    in if usedCount == 0 || usedCount == totalCount
          then Nothing
          else Just (map pick altStripped, map pick defStripped)

trySinkIntoArms : SortedMap Int Rep -> Int -> Rep -> RCExp -> RCExp -> Maybe RCExp
trySinkIntoArms reps var rep value (RCmpCase fc op args pd t f) =
    let consumed = consumedOperands reps value
    in case (stripForSink var fc consumed t, stripForSink var fc consumed f) of
            (Nothing, Just f') => Just $ RCmpCase fc op args pd (RLet fc var rep value t) f'
            (Just t', Nothing) => Just $ RCmpCase fc op args pd t' (RLet fc var rep value f)
            _ => Nothing
trySinkIntoArms reps var rep value (RConCase fc sc alts mDef) =
    case sinkIntoBodies fc var rep value (consumedOperands reps value)
           (map (\(MkRConAlt _ _ _ _ body) => body) alts) mDef of
         Nothing => Nothing
         Just (bodies', defBody') =>
             Just $ RConCase fc sc
               (zipWith (\alt, b => case alt of MkRConAlt n ci tag as _ => MkRConAlt n ci tag as b) alts bodies')
               defBody'
trySinkIntoArms reps var rep value (RConstCase fc sc alts mDef) =
    case sinkIntoBodies fc var rep value (consumedOperands reps value)
           (map (\(MkRConstAlt _ body) => body) alts) mDef of
         Nothing => Nothing
         Just (bodies', defBody') =>
             Just $ RConstCase fc sc
               (zipWith (\alt, b => case alt of MkRConstAlt c _ => MkRConstAlt c b) alts bodies')
               defBody'
trySinkIntoArms _ _ _ _ _ = Nothing

||| Whether `value` reads `l`: sinking `value` past a wrapper that drops,
||| frees or offers `l` would move that read after `l`'s release. See
||| doc/branch-sinking.md's "Not sinking a read past its operand's drop".
readBy : RCExp -> RCLocal -> Bool
readBy value l = contains l (genuinelyUsedR value)

||| Sees through the same leading `RDup`/`RDrop`/`RFree`/
||| `RReleaseReuse`/`RReuseOffer` wrappers `stripIfUnused` does,
||| bailing (`Nothing`) if a wrapper's own target is `var` itself --
||| sinking must stop at `var`'s own death, not peel through it. See
||| doc/branch-sinking.md's "Not peeling through var's own death" for
||| the miscompile (`TestBuffer`) this guards against.
|||
||| Also sees through a leading `RLet` for an unrelated local `y` (left
||| in place -- only survives to this point if `y` itself couldn't be
||| sunk, see `applySinkExp`'s own doc comment), bailing if `y`'s own
||| value reads `var`, *or* if `y`'s own value and `value` (the thing
||| being sunk) share any free local -- `y`'s value may be the sole
||| remaining consumer of that shared local's last owned reference, so
||| sinking `value` past it would read a reference `y`'s own value
||| already spent. See "Sinking past an unrelated let". Then checks
||| `isDecidingOperand` (see its own doc comment) before
||| dispatching to `trySinkIntoArms`.
trySinkInto : SortedMap Int Rep -> Int -> Rep -> RCExp -> RCExp -> Maybe RCExp
trySinkInto reps var rep value (RDup fc v extra cont) =
    if v == RCLoc var then Nothing else map (RDup fc v extra) (trySinkInto reps var rep value cont)
trySinkInto reps var rep value (RDrop fc vs cont) =
    if (RCLoc var `elem` vs) || any (readBy value) vs then Nothing else map (RDrop fc vs) (trySinkInto reps var rep value cont)
trySinkInto reps var rep value (RFree fc v cont) =
    if v == RCLoc var || readBy value v then Nothing else map (RFree fc v) (trySinkInto reps var rep value cont)
trySinkInto reps var rep value (RReleaseReuse fc v cont) =
    if v == RCLoc var || readBy value v then Nothing else map (RReleaseReuse fc v) (trySinkInto reps var rep value cont)
trySinkInto reps var rep value (RReuseOffer fc sc dupOnShared dropOnUnique cont) =
    if (sc == RCLoc var) || (RCLoc var `elem` dupOnShared) || (RCLoc var `elem` dropOnUnique)
         || any (readBy value) (sc :: dupOnShared ++ dropOnUnique)
       then Nothing
       else map (RReuseOffer fc sc dupOnShared dropOnUnique) (trySinkInto reps var rep value cont)
trySinkInto reps var rep value (RLet fc y repY valueY cont) =
    if contains (RCLoc var) (genuinelyUsedR valueY) || any (\l => contains l (genuinelyUsedR valueY)) (Prelude.toList (genuinelyUsedR value))
       then Nothing
       else map (RLet fc y repY valueY) (trySinkInto reps var rep value cont)
trySinkInto reps var rep value branch@(RCmpCase _ _ _ _ _ _) =
    if isDecidingOperand var value branch then Nothing else trySinkIntoArms reps var rep value branch
trySinkInto reps var rep value branch@(RConCase _ _ _ _) =
    if isDecidingOperand var value branch then Nothing else trySinkIntoArms reps var rep value branch
trySinkInto reps var rep value branch@(RConstCase _ _ _ _) =
    if isDecidingOperand var value branch then Nothing else trySinkIntoArms reps var rep value branch
trySinkInto _ _ _ _ _ = Nothing

------------------------------------------------------------------------
-- Whole-tree application.

||| Walks the whole tree innermost-first (an `RLet`'s own `body` is
||| fully sunk before trying to sink the `RLet` itself), and re-feeds a
||| successful sink back through itself so a chain of nested
||| single-use branches resolves in one pass with no fixed-point
||| driver -- always terminates, since each success strictly shrinks
||| the subtree `var`'s binding sits in. See doc/branch-sinking.md's
||| "Algorithm" and "Sinking arbitrarily deep, not just one level".
|||
||| `reps` threads which locals are known non-`RBoxed`, needed by
||| `consumedOperands` to tell a genuinely Boxed `RAppName` argument
||| from an already-native one -- same shape `Compiler.RC2.Loop`/
||| `Compiler.RC2.DualABI` already thread for the analogous reason.
||| Seeded empty (see `applySink` below), extended at every `RLet`
||| (its own declared `Rep`) and `RLoop` (its own `loopParams`).
export
applySinkExp : SortedMap Int Rep -> RCExp -> RCExp
applySinkExp reps (RLet fc var rep value body) =
    let value' = applySinkExp reps value
        reps' = insert var rep reps
        body' = applySinkExp reps' body
    in if sinkEligible value'
          then case trySinkInto reps' var rep value' body' of
                    Just sunk => applySinkExp reps sunk
                    Nothing => RLet fc var rep value' body'
          else RLet fc var rep value' body'
applySinkExp reps (RCmpCase fc op args pd t f) = RCmpCase fc op args pd (applySinkExp reps t) (applySinkExp reps f)
applySinkExp reps (RConCase fc sc alts mDef) =
    RConCase fc sc (map (\(MkRConAlt n ci tag as body) => MkRConAlt n ci tag as (applySinkExp reps body)) alts)
      (map (applySinkExp reps) mDef)
applySinkExp reps (RConstCase fc sc alts mDef) =
    RConstCase fc sc (map (\(MkRConstAlt c body) => MkRConstAlt c (applySinkExp reps body)) alts)
      (map (applySinkExp reps) mDef)
applySinkExp reps (RDup fc v extra body) = RDup fc v extra (applySinkExp reps body)
applySinkExp reps (RDrop fc vs body) = RDrop fc vs (applySinkExp reps body)
applySinkExp reps (RFree fc v body) = RFree fc v (applySinkExp reps body)
applySinkExp reps (RReleaseReuse fc v body) = RReleaseReuse fc v (applySinkExp reps body)
applySinkExp reps (RReuseOffer fc sc dupOnShared dropOnUnique body) = RReuseOffer fc sc dupOnShared dropOnUnique (applySinkExp reps body)
applySinkExp reps (RLoop fc loopParams initial prologueDrop body) =
    RLoop fc loopParams initial prologueDrop (applySinkExp (foldl (\m, (i, r) => insert i r m) reps loopParams) body)
applySinkExp reps (RMemoize fc n rep body) = RMemoize fc n rep (applySinkExp reps body)
applySinkExp _ e = e

||| Apply branch-local sinking to one top-level definition. Every
||| top-level argument is genuinely `RBoxed`, exactly `localRepIn`'s
||| own default for a missing id -- nothing to seed in `reps`.
export
applySink : RCDef -> RCDef
applySink (MkRCFun args retRep isWorker body) = MkRCFun args retRep isWorker (applySinkExp empty body)
applySink (MkRCError body) = MkRCError (applySinkExp empty body)
applySink d@(MkRCCon _ _ _) = d
applySink d@(MkRCForeign _ _ _) = d
