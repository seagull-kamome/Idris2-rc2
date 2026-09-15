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
import Core.Context.Log
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

||| One accepted clone: redirect a call to `callee` at `argPos` to
||| `cloneName` whenever the bound closure there resolves to `target`.
RedirectEntry : Type
RedirectEntry = (Nat, Name, Name)

||| All accepted clones, keyed by `callee` -- built once across every
||| specialization key and applied in a single whole-program pass (see
||| `applySpecClosure`'s own doc comment for why this replaced a
||| per-key `redirectCallSites` call).
RedirectTable : Type
RedirectTable = SortedMap Name (List RedirectEntry)

||| See the doc's "Internal structure" -> "Profitability +
||| redirection" paragraph. Generalized to consult every accepted
||| clone for `callee` in one pass, since a given call site's bound
||| closure can match at most one of them.
redirectCallSitesTable : RedirectTable -> RCExp -> RCExp
redirectCallSitesTable table = goBound empty
  where
    tryEntries : Bound -> FC -> Maybe LazyReason -> Name -> List RCLocal -> List RedirectEntry -> RCExp
    tryEntries bound fc lazy n args [] = RAppName fc lazy n args
    tryEntries bound fc lazy n args ((argPos, target, cloneName) :: rest) =
        case splitAt argPos args of
             (before, a :: after) =>
                 case lookupKnown bound a of
                      Just (MkKnownClosure t _ capturedArgs) =>
                          if t == target
                             then RAppName fc lazy cloneName (before ++ capturedArgs ++ after)
                             else tryEntries bound fc lazy n args rest
                      Nothing => tryEntries bound fc lazy n args rest
             _ => tryEntries bound fc lazy n args rest

    goBound : Bound -> RCExp -> RCExp
    goBound bound (RLet fc var rep value body) =
        let bound' = case value of
                          RUnderApp _ n missing capturedArgs => insert var (MkKnownClosure n missing capturedArgs) bound
                          _ => bound
        in RLet fc var rep (goBound bound value) (goBound bound' body)
    goBound bound (RAppName fc lazy n args) =
        case lookup n table of
             Nothing => RAppName fc lazy n args
             Just entries => tryEntries bound fc lazy n args entries
    goBound bound e = mapSubExprs (goBound bound) e

------------------------------------------------------------------------
-- Whole-program entry point
------------------------------------------------------------------------

||| One round of speculative closure-argument specialization. Not
||| iterated to a fixpoint -- see the doc's "Open questions" -> "Applied
||| once per compile" entry.
|||
||| Both the CAF table and call-site redirection are computed *once*
||| over the whole program -- `rebuildCafTable defs` up front, and a
||| `RedirectTable` accumulated across every key and applied in a
||| single final `redirectCallSitesTable` pass -- rather than once per
||| distinct specialization key. An earlier version rebuilt the CAF
||| table from, and redirected call sites across, the entire
||| accumulated definitions list on *every accepted key*: an
||| `O(distinct keys x program size)` cost that made this pass
||| impractically slow on a program the size of `idris2-lsp` (many
||| thousands of definitions, plausibly many distinct closure-argument
||| keys). This version is `O(program size)` overall (plus a small
||| `O(distinct keys)` for table bookkeeping). Reusing `defs`'s own CAF
||| facts (rather than each clone's) is correctness-equivalent: a
||| fresh clone's body only ever calls `target` (already known),
||| itself (already resolved via `rewriteSelfCall`), or whatever `g`'s
||| original body already called -- never another just-built clone
||| from an earlier key in the same pass.
|||
||| Diagnostic instrumentation below (`logTimeOver`, all at threshold 0
||| so every entry prints unconditionally, not gated behind any
||| `--timing`/log-level flag) is now just the four whole-pass-level
||| lines -- collect+group, the opportunity/key/def counts, the single
||| `rebuildCafTable`, and the single final redirect pass -- since
||| those are each `O(program size)` at most once per compile. The
||| earlier per-key `tryOneKey`/`buildClone+fold` lines (one pair per
||| distinct specialization key, unbounded on a program the size of
||| `idris2-lsp`) were removed once the `O(distinct keys x program
||| size)` slowdown they were added to diagnose was confirmed fixed.
export
applySpecClosure : List (Name, RCDef) -> Core (List (Name, RCDef))
applySpecClosure defs = do
    _ <- newRef FreshId 0
    keys <- logTimeOver 0 (pure "rc2: SpecClosure: collect+group opportunities") (pure (SortedMap.toList byKey))
    coreLift $ putStrLn $ "TIMING rc2: SpecClosure: " ++ show (length opportunities) ++ " opportunities, "
                           ++ show (length keys) ++ " distinct keys, " ++ show (length defs) ++ " defs"
    caf <- logTimeOver 0 (pure ("rc2: SpecClosure: rebuildCafTable (" ++ show (length defs) ++ " defs, once)"))
             (pure (rebuildCafTable defs))
    (newClones, table) <- goKeys defOf caf [] empty keys
    -- `newClones ++ defs`, not `defs ++ newClones`: matches the
    -- ordering the old per-key-accumulated `accDefs` produced (each
    -- accepted clone prepended, original defs at the tail), so
    -- emission's own ArgCounter-derived temp-variable numbering is
    -- unaffected by this refactor.
    logTimeOver 0 (pure ("rc2: SpecClosure: redirectAll (" ++ show (length defs + length newClones) ++ " defs, once)"))
      (pure $ map (\(n, d) => (n, case d of
                                        MkRCFun a r w body => MkRCFun a r w (redirectCallSitesTable table body)
                                        d' => d'))
                  (newClones ++ defs))
  where
    defOf : SortedMap Name RCDef
    defOf = SortedMap.fromList defs
    opportunities : List Opportunity
    opportunities = concatMap (\(_, d) => case d of MkRCFun _ _ _ body => collectOpportunities empty body; _ => []) defs
    -- `missing` is part of the key, not just `target` (doc's own
    -- "Internal structure" -> "Records" paragraph).
    byKey : SortedMap (Name, Nat, Name, Nat) (List Opportunity)
    byKey = foldl (\acc, opp => insertWith (++) (opp.callee, opp.argPos, opp.closure.target, opp.closure.missing) [opp] acc)
                  (the (SortedMap (Name, Nat, Name, Nat) (List Opportunity)) empty) opportunities

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

    ||| Builds and profitability-checks one clone for one key; `Just`
    ||| iff accepted. `caf` is the whole-program CAF table, built once
    ||| by the caller (see `applySpecClosure`'s own doc comment).
    tryOneKey : {auto fr : Ref FreshId Int} -> SortedMap Name RCDef -> CafTable -> Name -> Nat -> Name -> Nat -> List Opportunity -> Core (Maybe (Name, RCDef))
    tryOneKey defOf caf callee argPos target missing opps =
        case (lookup callee defOf, opps) of
             (Just gDef@(MkRCFun args retRep _ body), rep :: _) =>
                 case specializableParam callee argPos missing gDef of
                      Nothing => pure Nothing
                      Just paramVar => do
                          let capturedCount = length rep.closure.capturedArgs
                          (cloneName, unfoldedDef) <- buildClone callee argPos paramVar target missing capturedCount args retRep body
                          let cloneDef = foldConstDef caf unfoldedDef
                          let cloneDef'@(MkRCFun _ _ _ foldedBody) = cloneDef
                              | _ => pure Nothing
                          pure $ if stillAppliesParam paramVar foldedBody
                                    then Nothing
                                    else Just (cloneName, cloneDef')
             _ => pure Nothing

    -- `Core` has no `Monad` instance, so `Data.List.foldlM` doesn't
    -- apply -- a manual left fold over the discovered keys instead,
    -- threading the accepted-clones list and the redirect table
    -- (rather than a growing whole-program defs list) as the
    -- accumulators.
    goKeys : {auto fr : Ref FreshId Int}
          -> SortedMap Name RCDef -> CafTable -> List (Name, RCDef) -> RedirectTable
          -> List ((Name, Nat, Name, Nat), List Opportunity) -> Core (List (Name, RCDef), RedirectTable)
    goKeys _ _ newClones table [] = pure (newClones, table)
    goKeys defOf caf newClones table (((callee, argPos, target, missing), opps) :: rest) = do
        mClone <- tryOneKey defOf caf callee argPos target missing opps
        case mClone of
             Nothing => goKeys defOf caf newClones table rest
             Just (cloneName, cloneDef) =>
                 goKeys defOf caf ((cloneName, cloneDef) :: newClones)
                        (insertWith (++) callee [(argPos, target, cloneName)] table) rest
