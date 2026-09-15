||| Speculative, profitability-gated closure-argument specialization.
||| Design, motivation, and the reasoning behind every non-obvious
||| choice below live in `rc2/doc/speculative-closure-specialization.md`
||| (its own "Internal structure" section maps directly onto this
||| module's own functions) -- this file only comments *how*, not *why*.
||| Disable with `--directive nospecclosure`.
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
-- Shared structural recursion over this pass's own RCExp subset --
-- see the doc's "Internal structure" section, "Shared structural
-- recursion" paragraph.
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

||| See the doc's "Internal structure" -> "Records" paragraph.
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

||| See the doc's "Internal structure" -> "Records" paragraph.
Bound : Type
Bound = SortedMap Int KnownClosure

||| See the doc's "Internal structure" -> "Finding a known closure at a
||| use site" paragraph.
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
------------------------------------------------------------------------

||| See the doc's "Internal structure" -> "Chain detection" paragraph.
chainArgs : RCLocal -> Nat -> RCExp -> Maybe (List RCLocal)
chainArgs v (S Z) (RApp _ _ c a) = if c == v then Just [a] else Nothing
chainArgs v (S k@(S _)) (RLet _ t _ (RApp _ _ c a) cont) =
    if c == v then (a ::) <$> chainArgs (RCLoc t) k cont else Nothing
chainArgs _ _ _ = Nothing

||| See the doc's "Internal structure" -> "Self-recursive passthrough"
||| paragraph.
selfPassthroughOccurrences : RCLocal -> (callee : Name) -> (argPos : Nat) -> RCExp -> Nat
selfPassthroughOccurrences v callee argPos (RAppName _ _ n args) =
    if n == callee && getAt argPos args == Just v then 1 else 0
selfPassthroughOccurrences v callee argPos e = foldSubExprs (+) 0 (selfPassthroughOccurrences v callee argPos) e

||| `True` iff every occurrence of `v` in `e` is accounted for by
||| exactly one `missing`-long apply chain rooted at `v`, plus zero or
||| more self-recursive passthrough calls.
paramLooksSpecializable : RCLocal -> Nat -> (callee : Name) -> (argPos : Nat) -> RCExp -> Bool
paramLooksSpecializable v missing callee argPos e =
    let uses = countUsesR v e
        passthrough = selfPassthroughOccurrences v callee argPos e
    in uses > passthrough && (uses `minus` passthrough) == 1 && chainOccursIn v missing e
  where
    ||| `True` iff a `missing`-long `chainArgs` match for `v` occurs
    ||| anywhere in `e` -- see the doc's "Chain detection" paragraph for
    ||| why this searches every node, not just `e` itself.
    chainOccursIn : RCLocal -> Nat -> RCExp -> Bool
    chainOccursIn v missing e = isJust (chainArgs v missing e) || foldSubExprs (\a, b => a || b) False (chainOccursIn v missing) e

------------------------------------------------------------------------
-- Step 2: speculative clone + rewrite, one attempt per distinct
-- (callee, argPos, target, missing) key -- see the doc's "The proposed
-- rc2-native design" -> "2. Speculative clone + re-fold" for why
-- `capturedArgs`'s own values aren't part of that key.
------------------------------------------------------------------------

||| Rewrites the `missing`-long apply chain rooted at `paramVar` into a
||| direct call to `targetName`, fed `capturedParams` followed by the
||| chain's own applied arguments, in order.
rewriteApply : (paramVar : Int) -> (targetName : Name) -> (missing : Nat) -> (capturedParams : List Int) -> RCExp -> RCExp
rewriteApply paramVar targetName missing capturedParams = go
  where
    go : RCExp -> RCExp
    go e = case chainArgs (RCLoc paramVar) missing e of
                Just args => RAppName EmptyFC Nothing targetName (map RCLoc capturedParams ++ args)
                Nothing => mapSubExprs go e

||| See the doc's "Internal structure" -> "Safe fresh ids" paragraph
||| (including why this can't just use `FreshId`, and why it can't go
||| through `foldSubExprs`).
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
||| (`maxVarInBody`'s own result) -- `[]` for `n = Z`. See the doc's
||| "Safe fresh ids" paragraph for why this isn't `[1 .. n]`.
freshIdsFrom : Int -> Nat -> List Int
freshIdsFrom base Z = []
freshIdsFrom base (S k) = (base + 1) :: freshIdsFrom (base + 1) k

||| See the doc's "Internal structure" -> "Self-recursive passthrough"
||| paragraph.
rewriteSelfCall : (callee : Name) -> (argPos : Nat) -> (paramVar : Int) -> (cloneName : Name) -> (capturedParams : List Int) -> RCExp -> RCExp
rewriteSelfCall callee argPos paramVar cloneName capturedParams = go
  where
    go : RCExp -> RCExp
    go (RAppName fc lazy n args) =
        if n == callee && getAt argPos args == Just (RCLoc paramVar)
           then case splitAt argPos args of
                     (before, _ :: after) => RAppName fc lazy cloneName (before ++ map RCLoc capturedParams ++ after)
                     _ => RAppName fc lazy n args
           else RAppName fc lazy n args
    go e = mapSubExprs go e

||| Builds one specialized clone of `g` (`callee`; `paramVar`: the
||| `Int` id of its closure parameter at `argPos`) for one `(targetName,
||| missing, capturedCount)` triple -- see the doc's "Internal
||| structure" -> "Profitability + redirection" paragraph for
||| `capturedCount`'s own provenance. Not re-folded here --
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

||| `True` iff `e` still references `paramVar` -- see the doc's "The
||| proposed rc2-native design" -> "3. Profitability check" section.
stillAppliesParam : Int -> RCExp -> Bool
stillAppliesParam paramVar e = countUsesR (RCLoc paramVar) e > 0

||| See the doc's "Internal structure" -> "Profitability +
||| redirection" paragraph.
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

||| One round of speculative closure-argument specialization. Not
||| iterated to a fixpoint -- see the doc's "Open questions" -> "Applied
||| once per compile" entry.
export
applySpecClosure : List (Name, RCDef) -> Core (List (Name, RCDef))
applySpecClosure defs = do
    _ <- newRef FreshId 0
    let defOf : SortedMap Name RCDef := SortedMap.fromList defs
    let opportunities : List Opportunity :=
            concatMap (\(_, d) => case d of MkRCFun _ _ _ body => collectOpportunities empty body; _ => []) defs
    -- `missing` is part of the key, not just `target` (doc's own
    -- "Internal structure" -> "Records" paragraph).
    let byKey : SortedMap (Name, Nat, Name, Nat) (List Opportunity) :=
            foldl (\acc, opp => insertWith (++) (opp.callee, opp.argPos, opp.closure.target, opp.closure.missing) [opp] acc)
                  (the (SortedMap (Name, Nat, Name, Nat) (List Opportunity)) empty) opportunities
    goKeys defOf defs (SortedMap.toList byKey)
  where
    ||| `paramVar` at `argPos` in `g`'s own args, if it passes
    ||| `paramLooksSpecializable` for `missing`; `Nothing` otherwise.
    specializableParam : (callee : Name) -> Nat -> Nat -> RCDef -> Maybe Int
    specializableParam callee argPos missing (MkRCFun args _ _ body) =
        case getAt argPos args of
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

    -- `Core` has no `Monad` instance, so `Data.List.foldlM` doesn't
    -- apply -- a manual left fold over the discovered keys instead.
    goKeys : {auto fr : Ref FreshId Int}
          -> SortedMap Name RCDef -> List (Name, RCDef) -> List ((Name, Nat, Name, Nat), List Opportunity) -> Core (List (Name, RCDef))
    goKeys _ accDefs [] = pure accDefs
    goKeys defOf accDefs (((callee, argPos, target, missing), opps) :: rest) = do
        accDefs' <- tryOneKey defOf callee argPos target missing opps accDefs
        goKeys defOf accDefs' rest
