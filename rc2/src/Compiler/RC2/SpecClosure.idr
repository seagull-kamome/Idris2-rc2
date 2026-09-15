||| Speculative, profitability-gated closure-argument specialization.
||| See `rc2/doc/speculative-closure-specialization.md` for the full
||| design. Summary: for a function `g` whose parameter is used only
||| via `RApp` (a boxed closure dispatch) inside `g`'s own body, and
||| which is *always* called with one specific known closure target at
||| some subset of `g`'s call sites (program-wide, ignoring what free
||| variables that closure captures at each site -- weaker than
||| `%spec`'s own closedness requirement, see the doc's "Why not %spec"
||| section), clone `g` once per distinct target observed, rewrite the
||| clone's own `apply` into a direct `call`, and keep the clone only
||| if that direct call is no longer hidden behind any remaining
||| `apply` of the same kind after a fresh `ConstFold` over just the
||| clone -- discard it otherwise (a discarded clone is unreferenced,
||| costs nothing, and `Compiler.RC2.DeadCode` drops it like any other).
|||
||| Runs once, between `foldConstProgram` and `insertMemoize`
||| (`RC2.idr`'s `toRCDefs`) -- after `RUnderApp` targets are visible,
||| before Phase 2 (`annotate`) ever runs, so a kept clone is just one
||| more `MkRCFun` for the rest of the pipeline, no special handling
||| needed from `annotate`/`Reuse`/`ConAltNative`/`Loop`/etc.
|||
||| **Scope limits**:
||| - `missing > 1` (chained applies) *is* handled via `chainArgs` --
|||   `RApp`'s own two operands are bare `RCLocal`s, so a curried
|||   `f a1 a2` ANF-normalizes to `RLet tmp (RApp f a1) (RApp tmp a2)`,
|||   not one node. Only the *exact* chain shape is recognized; anything
|||   interposed leaves the whole chain unspecialized. This matters in
|||   practice: an ordinary `String -> IO ()` callback is `missing = 2`
|||   (real arg + the hidden `%World` token), never `missing = 1`.
||| - Re-running `Inline` on a clone (the paper design's other half of
|||   Step 2) is NOT implemented -- `Inline` is a whole-program
|||   `Lifted`-to-`Lifted` pass that already ran once, pre-RCExp;
|||   re-invoking it on one RCExp clone isn't something its current
|||   architecture supports. Only `ConstFold`'s `foldConstDef` is
|||   re-run here, so a call-free `target` isn't opportunistically
|||   inlined into the clone -- it stays a real direct call.
||| - Applied once per compile, not iterated to a fixpoint, by explicit
|||   request -- `applySpecClosure`'s own doc comment has the rationale.
module Compiler.RC2.SpecClosure

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Compiler.RC2.ConstFold
import Compiler.RC2.RCExp
import Compiler.RC2.Types
import Compiler.RC2.Util

import Core.Context
import Core.Core
import Core.FC
import Core.TT

import Data.DPair
import Data.List
import Data.Maybe
import Data.SortedMap
import Data.SortedSet

%default covering

------------------------------------------------------------------------
-- Shared structural recursion: `RLet`/`RCmpCase`/`RConCase`/
-- `RConstCase` are the only constructors that can hold a nested RCExp
-- in this pass's own input (strictly pre-Phase-2 -- no RDup/RDrop/
-- RFree/RReleaseReuse/RReuseOffer, RLoop/RLoopContinue, RAppNameRep/
-- RAppFFIInline, or RMemoize can occur here; all of those come from
-- later passes). Every walk below special-cases whichever constructor
-- it actually cares about and falls back to one of these two for the
-- rest, instead of re-deriving the same four cases repeatedly.
------------------------------------------------------------------------

mapAlt : (RCExp -> RCExp) -> RConAlt -> RConAlt
mapAlt f (MkRConAlt n ci tag as body) = MkRConAlt n ci tag as (f body)

mapConstAlt : (RCExp -> RCExp) -> RConstAlt -> RConstAlt
mapConstAlt f (MkRConstAlt c body) = MkRConstAlt c (f body)

||| Rebuild `e` by applying `f` to each immediate child.
mapSubExprs : (RCExp -> RCExp) -> RCExp -> RCExp
mapSubExprs f (RLet fc var rep value body) = RLet fc var rep (f value) (f body)
mapSubExprs f (RCmpCase fc op args postDrop t fa) = RCmpCase fc op args postDrop (f t) (f fa)
mapSubExprs f (RConCase fc sc alts mDef) = RConCase fc sc (map (mapAlt f) alts) (map f mDef)
mapSubExprs f (RConstCase fc sc alts mDef) = RConstCase fc sc (map (mapConstAlt f) alts) (map f mDef)
mapSubExprs _ e = e

||| Combine `f`'s result over each immediate child of `e` with `op`;
||| `z` both for a childless leaf and as the fold seed.
foldSubExprs : (a -> a -> a) -> a -> (RCExp -> a) -> RCExp -> a
foldSubExprs op _ f (RLet _ _ _ value body) = f value `op` f body
foldSubExprs op _ f (RCmpCase _ _ _ _ t fa) = f t `op` f fa
foldSubExprs op z f (RConCase _ _ alts mDef) = foldr op (maybe z f mDef) (map (\(MkRConAlt _ _ _ _ b) => f b) alts)
foldSubExprs op z f (RConstCase _ _ alts mDef) = foldr op (maybe z f mDef) (map (\(MkRConstAlt _ b) => f b) alts)
foldSubExprs _ z _ _ = z

------------------------------------------------------------------------
-- Step 1: whole-program call-site discovery
------------------------------------------------------------------------

||| A closure some call site is passing that's provably always one
||| `RUnderApp`'s value. `target`/`missing` are that `RUnderApp`'s own
||| first two fields (what must agree for two call sites to count as
||| "the same target"); `capturedArgs` is its third field, the actual
||| values closed over *at this call site* -- varies freely between
||| sites sharing the same target (doc's own `[v85,v80]` vs.
||| `[v200,v201]` example).
record KnownClosure where
  constructor MkKnownClosure
  target : Name
  missing : Nat
  capturedArgs : List RCLocal

||| One call site passing a `KnownClosure` at argument `argPos` of a
||| call to `callee`.
record Opportunity where
  constructor MkOpportunity
  callee : Name
  argPos : Nat
  closure : KnownClosure

||| `RCLocal`s, in the definition currently being walked, provably
||| bound (via an enclosing `RLet`) to a known `RUnderApp`, keyed by
||| their `Int` id. Built forward, never popped -- `normalizeDef`
||| assigns every id once, monotonically, per definition, so no id is
||| ever rebound within one definition's body.
Bound : Type
Bound = SortedMap Int KnownClosure

||| The `KnownClosure` an argument already carries: either `RCLoc i`
||| traced through `bound` to an enclosing `RUnderApp`, or a bare
||| `RCConstClosure n missing` (what a *zero*-capture `RUnderApp`
||| already becomes -- `ConstFold`'s own narrower constant-closure
||| folding, `doc/const-closure-fold.md`, substitutes it at every use
||| site directly, leaving no `Bound` entry to trace back to).
lookupKnown : Bound -> RCLocal -> Maybe KnownClosure
lookupKnown bound (RCLoc i) = lookup i bound
lookupKnown _ (RCConstClosure n missing) = Just (MkKnownClosure n missing [])
lookupKnown _ _ = Nothing

||| Every `Opportunity` in `e`, given `bound` from enclosing `RLet`s.
collectOpportunities : Bound -> RCExp -> List Opportunity
collectOpportunities bound (RLet _ var _ value body) =
    let bound' = case value of
                      RUnderApp _ n missing capturedArgs => insert var (MkKnownClosure n missing capturedArgs) bound
                      _ => bound
    in collectOpportunities bound value ++ collectOpportunities bound' body
collectOpportunities bound (RAppName _ _ callee args) =
    mapMaybe (\(i, a) => map (MkOpportunity callee i) (lookupKnown bound a)) (zip [0 .. length args] args)
collectOpportunities bound e = foldSubExprs (++) [] (collectOpportunities bound) e

------------------------------------------------------------------------
-- Step 1 (continued): is the parameter actually used only via `apply`
-- (possibly chained, possibly also passed through to self-recursion)?
-- If not, cloning buys nothing.
------------------------------------------------------------------------

||| If `e` is exactly a `missing`-long apply chain rooted at `v`,
||| returns the arguments applied, in order. `RApp`'s two operands are
||| bare `RCLocal`s (never a nested `RApp`), so `v a1 a2` (two more
||| args needed) ANF-normalizes to `RLet t (RApp v a1) (RApp t a2)`,
||| not one node -- this chases that shape level by level, `v` at the
||| first apply, each fresh intermediate at the next. The last apply
||| may be a bare tail expression instead of `RLet`-bound (nothing
||| inside the chain needs to name its result). `Nothing` on any other
||| shape -- no partial credit for an interrupted chain.
chainArgs : RCLocal -> Nat -> RCExp -> Maybe (List RCLocal)
chainArgs v (S Z) (RApp _ _ c a) = if c == v then Just [a] else Nothing
chainArgs v (S k@(S _)) (RLet _ t _ (RApp _ _ c a) cont) =
    if c == v then (a ::) <$> chainArgs (RCLoc t) k cont else Nothing
chainArgs _ _ _ = Nothing

||| `True` iff a `missing`-long `chainArgs` match for `v` occurs
||| anywhere in `e` -- tried at every node on the way down, since a
||| chain's own root can be any sub-expression (e.g. inside the value
||| of an unrelated enclosing `RLet`), not just `e` itself.
chainOccursIn : RCLocal -> Nat -> RCExp -> Bool
chainOccursIn v missing e = isJust (chainArgs v missing e) || foldSubExprs (\a, b => a || b) False (chainOccursIn v missing) e

||| `xs !! n`, `Maybe`-total.
nthArg : Nat -> List a -> Maybe a
nthArg _ [] = Nothing
nthArg Z (x :: _) = Just x
nthArg (S k) (_ :: xs) = nthArg k xs

||| How many of `v`'s occurrences in `e` are argument `argPos` of a
||| *self*-recursive call to `callee` -- `go (x::xs) f = f x >> go xs
||| f`'s own trailing `go xs f` is exactly this, and it's *expected*,
||| not disqualifying: any structurally-recursive traversal threads its
||| own closure argument through unchanged. `paramLooksSpecializable`
||| credits each of these instead of requiring `v` to occur exactly
||| once outright -- without this, no genuinely recursive `go`-shaped
||| function would ever qualify.
selfPassthroughOccurrences : RCLocal -> (callee : Name) -> (argPos : Nat) -> RCExp -> Nat
selfPassthroughOccurrences v callee argPos (RAppName _ _ n args) =
    if n == callee && nthArg argPos args == Just v then 1 else 0
selfPassthroughOccurrences v callee argPos e = foldSubExprs (+) 0 (selfPassthroughOccurrences v callee argPos) e

||| `True` iff every occurrence of `v` in `e` is accounted for by
||| exactly one `missing`-long apply chain rooted at `v`, plus zero or
||| more self-recursive passthrough calls.
paramLooksSpecializable : RCLocal -> Nat -> (callee : Name) -> (argPos : Nat) -> RCExp -> Bool
paramLooksSpecializable v missing callee argPos e =
    let uses = countUsesR v e
        passthrough = selfPassthroughOccurrences v callee argPos e
    in uses > passthrough && (uses `minus` passthrough) == 1 && chainOccursIn v missing e

------------------------------------------------------------------------
-- Step 2: speculative clone + rewrite, one attempt per distinct
-- (callee, argPos, target, missing) key -- `capturedArgs`'s own values
-- are deliberately not part of that key: two call sites capturing
-- different locals but naming the same target both redirect to the
-- one clone built for that target.
------------------------------------------------------------------------

||| Rewrites the `missing`-long apply chain rooted at `paramVar` into a
||| direct call to `targetName`, fed `capturedParams` (new parameters
||| standing in for whatever `target`'s own `RUnderApp` captured)
||| followed by the chain's own applied arguments, in order.
rewriteApply : (paramVar : Int) -> (targetName : Name) -> (missing : Nat) -> (capturedParams : List Int) -> RCExp -> RCExp
rewriteApply paramVar targetName missing capturedParams = go
  where
    go : RCExp -> RCExp
    go e = case chainArgs (RCLoc paramVar) missing e of
                Just args => RAppName EmptyFC Nothing targetName (map RCLoc capturedParams ++ args)
                Nothing => mapSubExprs go e

||| The largest `Int` var id bound anywhere in `e` (`RLet`/`RConAlt`
||| binders are the only sources of a *new* id; `normalizeDef` assigns
||| every id once, monotonically, per definition, so a definition's own
||| ids are exactly `[0 .. maxVarInBody]`, no gaps). `-1` for a body
||| binding nothing. Needed so `buildClone`'s new captured-value
||| parameters never collide with an id `g`'s own body already uses --
||| allocating them from this module's own `FreshId` instead (unrelated
||| to any one definition's own numbering) collides in practice.
|||
||| Deliberately does *not* go through `foldSubExprs`: unlike every
||| other walk in this module, this one also has to count `RConAlt`/
||| `RConstAlt`'s own pattern binders (`RConAlt`'s `args`), which
||| `foldSubExprs`'s generic per-child recursion has no hook for --
||| confirmed the hard way, as a real "redeclared with a different
||| kind of symbol" C compile error, when this was first tried.
maxVarInBody : List (Int, Rep) -> RCExp -> Int
maxVarInBody args body = max (foldl max (-1) (map fst args)) (go body)
  where
    mutual
      go : RCExp -> Int
      go (RLet _ var _ value body') = max var (max (go value) (go body'))
      go (RConCase _ _ alts mDef) = max (foldl max (-1) (map goAlt alts)) (maybe (-1) go mDef)
      go (RConstCase _ _ alts mDef) = max (foldl max (-1) (map goConstAlt alts)) (maybe (-1) go mDef)
      go e = foldSubExprs max (-1) go e

      goAlt : RConAlt -> Int
      goAlt (MkRConAlt _ _ _ as body') = max (foldl max (-1) as) (go body')

      goConstAlt : RConstAlt -> Int
      goConstAlt (MkRConstAlt _ body') = go body'

||| `n` fresh, sequential ids starting right after `base`
||| (`maxVarInBody`'s own result) -- `[]` for `n = Z`. Deliberately not
||| `[1 .. n]` range syntax: Idris2's own `Enum Nat` gives `[1 .. 0] =
||| [1, 0]`, not `[]`, which silently manufactured two spurious
||| captured parameters whenever `n` was genuinely 0 (caught by an
||| actual C compile failure before this fix).
freshIdsFrom : Int -> Nat -> List Int
freshIdsFrom base Z = []
freshIdsFrom base (S k) = (base + 1) :: freshIdsFrom (base + 1) k

||| Rewrites every self-recursive call to `callee` that passes
||| `paramVar` unchanged at `argPos` (`selfPassthroughOccurrences`'s
||| own shape) into a call to `cloneName`, splicing `capturedParams`
||| into that position instead (the clone's own signature has no slot
||| for the original closure argument at all). Without this, `go`'s own
||| trailing `go xs f` would keep recursing into the generic,
||| un-specialized `g`, specializing nothing past the first call.
rewriteSelfCall : (callee : Name) -> (argPos : Nat) -> (paramVar : Int) -> (cloneName : Name) -> (capturedParams : List Int) -> RCExp -> RCExp
rewriteSelfCall callee argPos paramVar cloneName capturedParams = go
  where
    go : RCExp -> RCExp
    go (RAppName fc lazy n args) =
        if n == callee && nthArg argPos args == Just (RCLoc paramVar)
           then case splitAt argPos args of
                     (before, _ :: after) => RAppName fc lazy cloneName (before ++ map RCLoc capturedParams ++ after)
                     _ => RAppName fc lazy n args
           else RAppName fc lazy n args
    go e = mapSubExprs go e

||| Builds one specialized clone of `g` (`callee`; `paramVar`: the
||| `Int` id of its closure parameter at `argPos`) for one `(targetName,
||| missing, capturedCount)` triple. `capturedCount` comes from one
||| witnessing call site's own `capturedArgs` length -- consistent
||| across every call site sharing this key by construction (same
||| `target` name/arity everywhere). Not re-folded here --
||| `applySpecClosure` does that once, after this returns.
buildClone : {auto fr : Ref FreshId Int}
          -> (callee : Name) -> (argPos : Nat)
          -> (paramVar : Int) -> (targetName : Name) -> (missing : Nat) -> (capturedCount : Nat)
          -> (args : List (Int, Rep)) -> (retRep : Rep) -> (body : RCExp)
          -> Core (Name, RCDef)
buildClone callee argPos paramVar targetName missing capturedCount args retRep body = do
    cloneId <- freshId
    let capturedParams = freshIdsFrom (maxVarInBody args body) capturedCount
    let cloneName = MN "rc2_specClosure" cloneId
    let args' = concatMap (\(i, r) => if i == paramVar
                                          then map (\p => (p, RBoxed)) capturedParams
                                          else [(i, r)]) args
    let body' = rewriteSelfCall callee argPos paramVar cloneName capturedParams
                    (rewriteApply paramVar targetName missing capturedParams body)
    pure (cloneName, MkRCFun args' retRep False body')

------------------------------------------------------------------------
-- Step 3: profitability check + call-site redirection
------------------------------------------------------------------------

||| `True` iff `e` still references `paramVar` -- the closure escaped
||| somewhere the fold couldn't reach (stored, returned, applied inside
||| an unresolved branch, ...), so the clone bought nothing.
stillAppliesParam : Int -> RCExp -> Bool
stillAppliesParam paramVar e = countUsesR (RCLoc paramVar) e > 0

||| Every call to `callee` passing a `KnownClosure` matching `target`
||| at `argPos`, redirected to `cloneName` with that argument replaced
||| by its own capture list (matching the clone's reduced arity). A
||| call site naming a *different* target is left alone -- it keeps
||| calling the generic, un-cloned `g`.
redirectCallSites : (callee : Name) -> (argPos : Nat) -> (target : Name) -> (cloneName : Name) -> RCExp -> RCExp
redirectCallSites callee argPos target cloneName = goBound empty
  where
    goBound : Bound -> RCExp -> RCExp
    goBound bound (RLet fc var rep value body) =
        let bound' = case value of
                          RUnderApp _ n missing capturedArgs => insert var (MkKnownClosure n missing capturedArgs) bound
                          _ => bound
        in RLet fc var rep (goBound bound value) (goBound bound' body)
    goBound bound (RAppName fc lazy n args) =
        if n == callee
           then case splitAt argPos args of
                     (before, a :: after) =>
                         case lookupKnown bound a of
                              Just (MkKnownClosure t _ capturedArgs) =>
                                  if t == target then RAppName fc lazy cloneName (before ++ capturedArgs ++ after) else RAppName fc lazy n args
                              Nothing => RAppName fc lazy n args
                     _ => RAppName fc lazy n args
           else RAppName fc lazy n args
    goBound bound e = mapSubExprs (goBound bound) e

------------------------------------------------------------------------
-- Whole-program entry point
------------------------------------------------------------------------

||| One round of speculative closure-argument specialization.
|||
||| Non-iterating by explicit request: a kept clone's own body can, in
||| principle, expose a fresh opportunity of its own (calling another
||| generic higher-order function with a now-constant closure it didn't
||| have before), the same way `foldConstProgram` re-runs `ConstFold`
||| to a fixpoint because one CAF's fold can unblock another. Not
||| attempted -- re-run this function on its own output, or a small
||| `go fuel defs` loop mirroring `foldConstProgram`'s shape, once real
||| evidence calls for it; nothing here needs to change to support that.
export
applySpecClosure : List (Name, RCDef) -> Core (List (Name, RCDef))
applySpecClosure defs = do
    _ <- newRef FreshId 0
    let defOf : SortedMap Name RCDef := SortedMap.fromList defs
    let opportunities : List Opportunity :=
            concatMap (\(_, d) => case d of MkRCFun _ _ _ body => collectOpportunities empty body; _ => []) defs
    -- `missing` is part of the key, not just `target` -- the same
    -- function captured at two different under-application depths
    -- needs two different clones (differing `capturedCount`).
    let byKey : SortedMap (Name, Nat, Name, Nat) (List Opportunity) :=
            foldl (\acc, opp => insertWith (++) (opp.callee, opp.argPos, opp.closure.target, opp.closure.missing) [opp] acc)
                  (the (SortedMap (Name, Nat, Name, Nat) (List Opportunity)) empty) opportunities
    goKeys defOf defs (SortedMap.toList byKey)
  where
    ||| `paramVar` at `argPos` in `g`'s own args, if it passes
    ||| `paramLooksSpecializable` for `missing`; `Nothing` otherwise.
    specializableParam : (callee : Name) -> Nat -> Nat -> RCDef -> Maybe Int
    specializableParam callee argPos missing (MkRCFun args _ _ body) =
        case nthArg argPos args of
             Just (i, _) => if paramLooksSpecializable (RCLoc i) missing callee argPos body then Just i else Nothing
             Nothing => Nothing
    specializableParam _ _ _ _ = Nothing

    rebuildCafTable : List (Name, RCDef) -> CafTable
    rebuildCafTable = foldl (\tbl, (n, d) => maybe tbl (\v => insert n v tbl) (cafValueOf d)) empty

    redirectAll : Name -> Nat -> Name -> Name -> List (Name, RCDef) -> List (Name, RCDef)
    redirectAll callee argPos target cloneName =
        map (\(n, d) => (n, case d of
                                 MkRCFun a r w body => MkRCFun a r w (redirectCallSites callee argPos target cloneName body)
                                 d' => d'))

    tryOneKey : {auto fr : Ref FreshId Int} -> SortedMap Name RCDef -> Name -> Nat -> Name -> Nat -> List Opportunity -> List (Name, RCDef) -> Core (List (Name, RCDef))
    tryOneKey defOf callee argPos target missing opps accDefs =
        case (lookup callee defOf, opps) of
             (Just gDef@(MkRCFun args retRep _ body), rep :: _) =>
                 case specializableParam callee argPos missing gDef of
                      Nothing => pure accDefs
                      Just paramVar => do
                          let capturedCount = length rep.closure.capturedArgs
                          (cloneName, cloneDef) <- buildClone callee argPos paramVar target missing capturedCount args retRep body
                          let cloneDef'@(MkRCFun _ _ _ foldedBody) = foldConstDef (rebuildCafTable accDefs) cloneDef
                              | _ => pure accDefs
                          pure $ if stillAppliesParam paramVar foldedBody
                                    then accDefs
                                    else redirectAll callee argPos target cloneName ((cloneName, cloneDef') :: accDefs)
             _ => pure accDefs

    -- `Core` has no `Monad` instance (this project's own hand-rolled
    -- effect monad), so `Data.List.foldlM` doesn't apply -- a manual
    -- left fold over the discovered keys instead.
    goKeys : {auto fr : Ref FreshId Int}
          -> SortedMap Name RCDef -> List (Name, RCDef) -> List ((Name, Nat, Name, Nat), List Opportunity) -> Core (List (Name, RCDef))
    goKeys _ accDefs [] = pure accDefs
    goKeys defOf accDefs (((callee, argPos, target, missing), opps) :: rest) = do
        accDefs' <- tryOneKey defOf callee argPos target missing opps accDefs
        goKeys defOf accDefs' rest
