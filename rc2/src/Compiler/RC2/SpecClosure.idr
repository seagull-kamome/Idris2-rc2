||| Speculative, profitability-gated closure-argument specialization.
||| Design, motivation, and the reasoning behind every non-obvious
||| choice below live in `rc2/doc/speculative-closure-specialization.md`
||| (its own "Internal structure" section maps directly onto this
||| module's own functions) -- this file only comments *how*, not *why*.
||| Disable with `--directive nospecclosure`. Its own whole-pass-level
||| timing/count diagnostics (`applySpecClosure`'s own
||| `maybeLogTimeOver`) only print with `--directive timing`.
|||
||| A second, sibling pass lives in this module's own lower half:
||| `applySpecConstCon`, which specializes on a *constant-constructor*
||| argument (an interface dictionary) rather than a closure one. It
||| shares this module's structural helpers and pipeline position but
||| is a separate stage, disabled separately with
||| `--directive nospecconstcon`; see
||| `rc2/doc/constant-constructor-specialization.md`.
module Compiler.RC2.SpecClosure

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Compiler.RC2.ConstFold
import Compiler.RC2.Emit.Util
import Compiler.RC2.RCExp
import Compiler.RC2.Types
import Compiler.RC2.Util

import Core.Context
import Core.Context.Log
import Core.Core
import Core.FC
import Core.Options
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

||| See the doc's "Internal structure" -> "Chain detection" paragraph,
||| and `doc/rapp-nary-closure-apply.md`'s own "A free simplification
||| this exposed" section for why this only *partly* collapsed once
||| `RApp` itself gained a `List RCLocal` args field: a source-level
||| `v x y` now reaches here as one `RApp v [x, y]` node already
||| (`Compiler.RC2.RC`'s `collectAppChain` merges it at Phase 1), so
||| the exact-match case below is now the common one -- but a genuinely
||| let-bound intermediate partial application (`let partial = v x in
||| ... partial y ...`, two syntactically separate applications in the
||| source) still reaches here as two distinct `RApp` nodes threaded by
||| an `RLet`, each contributing however many args *its own* hop
||| carries (no longer always exactly one), so the chained case still
||| has real work to do.
chainArgs : RCLocal -> Nat -> RCExp -> Maybe (List RCLocal)
chainArgs v missing (RLet _ t _ (RApp _ _ c args) cont) =
    if c == v && length args < missing
       then (args ++) <$> chainArgs (RCLoc t) (missing `minus` length args) cont
       else Nothing
chainArgs v missing (RApp _ _ c args) =
    if c == v && length args == missing then Just args else Nothing
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
|||
||| `capturedParams`'s own fresh ids come from the shared, whole-
||| compile `VarId` counter (`Compiler.RC2.Util`) -- guaranteed not to
||| collide with `g`'s own existing ids (or anything else in the
||| program) without needing to scan `g`'s body for its current
||| highest id first, unlike `cloneId` (`FreshId`, a *name*-numbering
||| counter, disjoint from `VarId`'s var-id numbering -- see that
||| type's own doc comment for why the two stay separate).
buildClone : {auto fr : Ref FreshId Int} -> {auto v : Ref VarId Int}
          -> (callee : Name) -> (argPos : Nat)
          -> (paramVar : Int) -> (targetName : Name) -> (missing : Nat) -> (capturedCount : Nat)
          -> (args : List (Int, Rep)) -> (retRep : Rep) -> (body : RCExp)
          -> Core (Name, RCDef)
buildClone callee argPos paramVar targetName missing capturedCount args retRep body = do
    cloneId <- freshId
    capturedParams <- traverse (const freshVarId) (replicate capturedCount ())
    -- Embeds `callee`'s own mangled name (`cName`, exported by
    -- `Compiler.RC2.Emit.Util` for exactly this reuse) the same way
    -- `Compiler.RC2.DualABI`'s own `freshName` already does for a
    -- worker's own name -- a `dumprcexpr`/generated-`.c` reader sees
    -- which original function a given clone specializes on sight,
    -- rather than only an opaque counter.
    let cloneName = MN ("rc2_specClosure_" ++ cName callee) cloneId
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
||| Diagnostic instrumentation below (`logTimeOver` at threshold 0, so
||| it would print unconditionally if reached at all) is now just the
||| four whole-pass-level lines -- collect+group, the opportunity/key/
||| def counts, the single `rebuildCafTable`, and the single final
||| redirect pass -- since those are each `O(program size)` at most
||| once per compile. The earlier per-key `tryOneKey`/`buildClone+fold`
||| lines (one pair per distinct specialization key, unbounded on a
||| program the size of `idris2-lsp`) were removed once the
||| `O(distinct keys x program size)` slowdown they were added to
||| diagnose was confirmed fixed. Originally left unconditional
||| (bypassing `--timing`/log-level entirely) since that diagnosis was
||| still ongoing; now gated behind `maybeLogTimeOver`'s own
||| `--directive timing` check below, same as every other pass' own
||| `logTime` calls, since that investigation concluded and these lines
||| were just unconditional noise on every single build otherwise.
maybeLogTimeOver : Bool -> Integer -> Core String -> Core a -> Core a
maybeLogTimeOver True nsecs str act = logTimeOver nsecs str act
maybeLogTimeOver False _ _ act = act

export
applySpecClosure : {auto c : Ref Ctxt Defs} -> {auto v : Ref VarId Int} -> List (Name, RCDef) -> Core (List (Name, RCDef))
applySpecClosure defs = do
    _ <- newRef FreshId 0
    timingEnabled <- elem "timing" <$> getDirectives (Other "rc2")
    keys <- maybeLogTimeOver timingEnabled 0 (pure "rc2: SpecClosure: collect+group opportunities") (pure (SortedMap.toList byKey))
    when timingEnabled $
      coreLift $ putStrLn $ "TIMING rc2: SpecClosure: " ++ show (sum (map (length . snd) keys)) ++ " opportunities, "
                             ++ show (length keys) ++ " distinct keys, " ++ show (length defs) ++ " defs"
    caf <- maybeLogTimeOver timingEnabled 0 (pure ("rc2: SpecClosure: rebuildCafTable (" ++ show (length defs) ++ " defs, once)"))
             (pure (rebuildCafTable defs))
    (newClones, table) <- goKeys defOf caf [] empty keys
    -- `newClones ++ defs`, not `defs ++ newClones`: matches the
    -- ordering the old per-key-accumulated `accDefs` produced (each
    -- accepted clone prepended, original defs at the tail), so
    -- emission's own ArgCounter-derived temp-variable numbering is
    -- unaffected by this refactor.
    maybeLogTimeOver timingEnabled 0 (pure ("rc2: SpecClosure: redirectAll (" ++ show (length defs + length newClones) ++ " defs, once)"))
      (pure $ map (\(n, d) => (n, case d of
                                        MkRCFun a r w body => MkRCFun a r w (redirectCallSitesTable table body)
                                        d' => d'))
                  (newClones ++ defs))
  where
    -- Referenced exactly once, at the `goKeys defOf ...` call above,
    -- which then threads it as a parameter. That is load-bearing, not
    -- style: a `where` definition is lambda-lifted into a function of
    -- the enclosing pattern variables it mentions, so every *further*
    -- reference here would rebuild the whole map. See
    -- `applySpecConstCon`'s own `defOf` for what that costs when the
    -- reference sits inside the per-key loop instead.
    defOf : SortedMap Name RCDef
    defOf = SortedMap.fromList defs
    -- `missing` is part of the key, not just `target` (doc's own
    -- "Internal structure" -> "Records" paragraph).
    addOpp : SortedMap (Name, Nat, Name, Nat) (List Opportunity) -> Opportunity
          -> SortedMap (Name, Nat, Name, Nat) (List Opportunity)
    addOpp acc opp = insertWith (++) (opp.callee, opp.argPos, opp.closure.target, opp.closure.missing) [opp] acc

    -- Groups each definition's own opportunities into the map as they
    -- are collected, rather than flattening them into one list first
    -- (`concatMap`, the obvious spelling): `concat` left-nests `++`, so
    -- every definition's list gets copied past the whole prefix built
    -- so far. Measured on `idris2-lsp` (32.4k definitions, 12.2k
    -- opportunities): ~0.9s of this pass's own time went there. Same
    -- trap, and same fix, as `Compiler.RC2.LateInline`'s own `analyse`.
    byKey : SortedMap (Name, Nat, Name, Nat) (List Opportunity)
    byKey = foldl (\acc, (_, d) => case d of
                        MkRCFun _ _ _ body => foldl addOpp acc (collectOpportunities empty body)
                        _ => acc)
                  (the (SortedMap (Name, Nat, Name, Nat) (List Opportunity)) empty) defs

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

------------------------------------------------------------------------
-- Constant-constructor argument specialization
--
-- The sibling of everything above, aimed at the one remaining
-- structurally-resolvable source of boxed `idris2rc2_applyClosure`
-- dispatch: an interface dictionary. There the specialized parameter
-- isn't a closure that gets *applied*, it's a record that gets
-- *destructured*, so none of the machinery above recognises it:
--
--   def Prelude.Types.elemBy (args= [v10077, v10078, v10079])
--     case v10077 of                                    -- destructure
--       MkFoldable [record] args= [_, _, _, _, _, v10085] ->
--         apply v10085 [..., v10087]                    -- boxed dispatch
--
-- Nothing new is needed downstream -- only getting the constant to the
-- callee's own body. `Compiler.RC2.ConstFold` then folds the `case`
-- away against it, binds each alt field to the corresponding constant,
-- and (since each method field is an `RCConstClosure`) rewrites every
-- `apply` of one into a direct `RAppName` call. That is why this needs
-- no `rewriteApply` analogue at all: seeding the fold IS the rewrite.
--
-- Steps 1-3 deliberately mirror the closure case above, so its own
-- profitability discipline carries over unchanged. See
-- `rc2/doc/constant-constructor-specialization.md` for the design, the
-- measured opportunity, and why this pass was once rejected outright
-- over a cost that turned out not to be its own.
------------------------------------------------------------------------

||| One call site passing constant constructor `value` at argument
||| `argPos` of a call to `callee`.
record ConstOpportunity where
  constructor MkConstOpportunity
  callee : Name
  argPos : Nat
  value : RCLocal

||| Every `ConstOpportunity` in `e`. Unlike `collectOpportunities`
||| above there is no `Bound` to thread: `ConstFold` has already run to
||| a fixpoint over the whole program by the time this pass does, so a
||| constant argument is already spelled out as an `RCConstCon` right
||| at the call site, never still behind an `RLet`.
collectConstOpportunities : RCExp -> List ConstOpportunity
collectConstOpportunities (RAppName _ _ callee args) =
    mapMaybe (\(i, a) => case a of
                              RCConstCon {} => Just (MkConstOpportunity callee i a)
                              _ => Nothing)
             (zip [0 .. length args] args)
collectConstOpportunities e = foldSubExprs (++) [] collectConstOpportunities e

||| Occurrences of `p` sitting in an `RConCase`'s own scrutinee
||| position, anywhere in `e`.
scrutineeUses : RCLocal -> RCExp -> Nat
scrutineeUses p e@(RConCase _ sc _ _) =
    (if sc == p then 1 else 0) + foldSubExprs (+) 0 (scrutineeUses p) e
scrutineeUses p e = foldSubExprs (+) 0 (scrutineeUses p) e

||| `True` iff every occurrence of `p` in `e` is an `RConCase`
||| scrutinee. Anything else -- stored into a constructor, passed on to
||| another call, returned -- means substituting the constant would
||| duplicate it into positions the fold can't collapse, so the clone
||| would be a second copy of the same work rather than a
||| specialization. The profitability gate would reject such a clone
||| anyway; refusing here just avoids building it.
|||
||| Note this pass runs *before* `Compiler.RC2.RC`'s own `annotate`, so
||| there are no `RDup`/`RDrop` occurrences to discount yet -- see
||| `applySpecClosure`'s own pipeline position.
paramIsScrutineeOnly : RCLocal -> RCExp -> Bool
paramIsScrutineeOnly p e =
    let uses = countUsesR p e
    in uses > 0 && uses == scrutineeUses p e

||| Total `RApp` (boxed closure dispatch) nodes in `e` -- the
||| profitability measure for this half of the pass.
countApps : RCExp -> Nat
countApps e@(RApp {}) = 1 + foldSubExprs (+) 0 countApps e
countApps e = foldSubExprs (+) 0 countApps e

||| `countApps` over a whole definition.
defApps : RCDef -> Nat
defApps (MkRCFun _ _ _ body) = countApps body
defApps (MkRCError body) = countApps body
defApps _ = 0

||| Clone `callee` with its `argPos` parameter dropped from the
||| signature and its id seeded to `value` for the fold. The body is
||| handed over unchanged -- `foldConstDefWith` does the substitution,
||| the `case` collapse and the `apply`-to-`call` rewrite in one go.
buildConstClone : {auto fr : Ref FreshId Int}
               -> CafTable -> (callee : Name) -> (argPos : Nat) -> (value : RCLocal)
               -> (args : List (Int, Rep)) -> (retRep : Rep) -> (body : RCExp)
               -> Core (Maybe (Name, RCDef))
buildConstClone caf callee argPos value args retRep body =
    case getAt argPos args of
         Nothing => pure Nothing
         Just (paramVar, _) =>
             if not (paramIsScrutineeOnly (RCLoc paramVar) body)
                then pure Nothing
                else do
                    cloneId <- freshId
                    -- Same naming scheme as `buildClone` above, with
                    -- its own prefix so the two are told apart on sight
                    -- in a `dumprcexpr`/generated-`.c` read.
                    let cloneName = MN ("rc2_specConst_" ++ cName callee) cloneId
                    let args' = filter (\(i, _) => i /= paramVar) args
                    let folded = foldConstDefWith caf [(paramVar, value)] (MkRCFun args' retRep False body)
                    pure $ if defApps folded < countApps body then Just (cloneName, folded) else Nothing

||| One accepted constant-constructor clone: redirect a call to
||| `callee` to `cloneName`, dropping argument `argPos`, whenever the
||| argument there is exactly `value`.
ConstRedirectEntry : Type
ConstRedirectEntry = (Nat, RCLocal, Name)

ConstRedirectTable : Type
ConstRedirectTable = SortedMap Name (List ConstRedirectEntry)

redirectConstCallSites : ConstRedirectTable -> RCExp -> RCExp
redirectConstCallSites table = go
  where
    tryEntries : FC -> Maybe LazyReason -> Name -> List RCLocal -> List ConstRedirectEntry -> RCExp
    tryEntries fc lazy n args [] = RAppName fc lazy n args
    tryEntries fc lazy n args ((argPos, value, cloneName) :: rest) =
        case splitAt argPos args of
             (before, a :: after) =>
                 if a == value
                    then RAppName fc lazy cloneName (before ++ after)
                    else tryEntries fc lazy n args rest
             _ => tryEntries fc lazy n args rest

    go : RCExp -> RCExp
    go (RAppName fc lazy n args) =
        case lookup n table of
             Nothing => RAppName fc lazy n args
             Just entries => tryEntries fc lazy n args entries
    go e = mapSubExprs go e

||| One round of constant-constructor argument specialization, run
||| straight after `applySpecClosure` and sharing its pipeline
||| position. Structured exactly like it: group call sites by
||| `(callee, argPos, value)`, attempt one memoized clone per distinct
||| key, accumulate a redirect table, and apply it in a single
||| whole-program pass at the end.
export
applySpecConstCon : {auto c : Ref Ctxt Defs} -> List (Name, RCDef) -> Core (List (Name, RCDef))
applySpecConstCon defs = do
    _ <- newRef FreshId 0
    timingEnabled <- elem "timing" <$> getDirectives (Other "rc2")
    let keys = SortedMap.toList byKey
    when timingEnabled $
      coreLift $ putStrLn $ "TIMING rc2: SpecConstCon: " ++ show (length keys)
                             ++ " distinct keys, " ++ show (length defs) ++ " defs"
    let caf = rebuildCafTable defs
    -- Bound in the body, ONCE, and threaded into `goKeys` as a
    -- parameter -- deliberately NOT a `where` clause. A `where`
    -- definition is lambda-lifted into a function of whatever
    -- enclosing pattern variables it mentions, so a nullary-looking
    -- `defOf = SortedMap.fromList defs` there is really `defOf defs`,
    -- rebuilt from scratch at *every* use. `goKeys`'s own `lookup
    -- callee defOf` runs once per key, so writing it that way cost
    -- ~1600 rebuilds of a 38k-entry map: 103s of a 131s whole-
    -- `idris2-lsp` build, against 0.01s once hoisted. That single
    -- difference is what made this pass look unaffordable and get
    -- reverted the first time round. `applySpecClosure` above gets
    -- this right the same way, by passing its own `defOf` to its own
    -- `goKeys` rather than referring to it per call site.
    let defOf : SortedMap Name RCDef := SortedMap.fromList defs
    (newClones, table) <- goKeys defOf caf [] empty keys
    pure $ map (\(n, d) => (n, case d of
                                    MkRCFun a r w body => MkRCFun a r w (redirectConstCallSites table body)
                                    d' => d'))
               (newClones ++ defs)
  where
    addOpp : SortedMap (Name, Nat, RCLocal) () -> ConstOpportunity -> SortedMap (Name, Nat, RCLocal) ()
    addOpp acc opp = insert (opp.callee, opp.argPos, opp.value) () acc

    -- Only the distinct keys matter here (unlike the closure case,
    -- where one representative opportunity carries the captured-arg
    -- count), so this groups into a set rather than a list-valued map
    -- -- and, same trap as above, folds into it per definition instead
    -- of flattening every definition's own list together first.
    byKey : SortedMap (Name, Nat, RCLocal) ()
    byKey = foldl (\acc, (_, d) => case d of
                        MkRCFun _ _ _ body => foldl addOpp acc (collectConstOpportunities body)
                        _ => acc)
                  (the (SortedMap (Name, Nat, RCLocal) ()) empty) defs

    rebuildCafTable : List (Name, RCDef) -> CafTable
    rebuildCafTable = foldl (\tbl, (n, d) => maybe tbl (\v => insert n v tbl) (cafValueOf d)) empty

    goKeys : {auto fr : Ref FreshId Int}
          -> SortedMap Name RCDef -> CafTable -> List (Name, RCDef) -> ConstRedirectTable
          -> List ((Name, Nat, RCLocal), ()) -> Core (List (Name, RCDef), ConstRedirectTable)
    goKeys _ _ newClones table [] = pure (newClones, table)
    goKeys defOf caf newClones table (((callee, argPos, value), _) :: rest) =
        case lookup callee defOf of
             Just (MkRCFun args retRep False body) => do
                 mClone <- buildConstClone caf callee argPos value args retRep body
                 case mClone of
                      Nothing => goKeys defOf caf newClones table rest
                      Just (cloneName, cloneDef) =>
                          goKeys defOf caf ((cloneName, cloneDef) :: newClones)
                                 (insertWith (++) callee [(argPos, value, cloneName)] table) rest
             -- A worker (`isWorker`) can't exist yet at this point in
             -- the pipeline, and anything that isn't a plain function
             -- has no parameter to specialize.
             _ => goKeys defOf caf newClones table rest
