||| Whole-program `RCExp`-to-`RCExp` inlining, run late in the pipeline
||| (after `Compiler.RC2.Loop`/`MutualLoop`) -- currently splices a
||| callee's body directly into its own call site whenever that's the
||| *only* place, anywhere in the program, it's ever called; a future
||| session may extend eligibility beyond single-caller, which is why
||| this module/pass isn't named after that one criterion specifically.
||| See `rc2/doc/inlining.md`'s "Criterion B, revisited" section for
||| the full design (why this needed to wait until after Loop
||| conversion, why every one of the callee's own ids -- top-level
||| params and internal alike -- needs renaming on the way in despite
||| `VarId` already being globally unique, and the cycle-exclusion
||| argument). Disable with `--directive nolateinline`.
module Compiler.RC2.LateInline

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Compiler.RC2.Loop
import Compiler.RC2.MutualLoop
import Compiler.RC2.RCExp
import Compiler.RC2.Types
import Compiler.RC2.Util

import Core.Context
import Core.Core
import Core.FC
import Core.TT

import Data.List
import Data.Maybe
import Data.SortedMap
import Data.SortedSet

%default covering

------------------------------------------------------------------------
-- Whole-program call-site counting + call graph (cycle exclusion)
------------------------------------------------------------------------

||| Every name `d`'s own body directly, saturated-ly calls (`RAppName`
||| only) -- see the doc's "Eligibility" section for why `RUnderApp`/
||| `RCConstClosure`/`RCon`/`RAppNameRep` references don't matter here.
calleesOf : RCDef -> SortedSet Name
calleesOf = foldRCNamesD ({ onAppName := \n, _ => singleton n } noRCNames)

||| One `[n]` per `RAppName` call to `n`, whole-program -- summed into
||| `callCounts` below.
callOccurrencesOf : RCDef -> List Name
callOccurrencesOf = foldRCNamesD ({ onAppName := \n, _ => [n] } noRCNames)

record Analysis where
  constructor MkAnalysis
  ||| Whole-program call graph, `RAppName` edges only -- every
  ||| definition is a key, even a leaf with no outgoing calls (`Graph`
  ||| itself, and `tarjanSCCs`'s own traversal, needs every node
  ||| present to visit it).
  graph : Graph
  ||| Total `RAppName` occurrences of each name, whole-program.
  callCounts : SortedMap Name Nat
  ||| Every eligible callee: exactly one call site anywhere, a genuine
  ||| `MkRCFun` (not `RCCon`/`RCForeign`/`RCError`), and not part of any
  ||| cycle (a size>=2 SCC, or a direct self-edge) in `graph`.
  eligible : SortedSet Name
  ||| Every name, callees before callers where the call graph orders
  ||| them at all (`tarjanSCCs`'s own bottom-up ordering, reused
  ||| verbatim from `Compiler.RC2.MutualLoop` -- see the doc for why
  ||| this lets a whole *chain* of single-caller callees collapse in
  ||| one pass instead of needing to be re-run per link).
  processOrder : List Name

analyse : List (Name, RCDef) -> Analysis
analyse defs =
    let graph = SortedMap.fromList $ map (\(n, d) => (n, calleesOf d)) defs
        callCounts = foldl (\acc, n => insertWith (+) n 1 acc) (the (SortedMap Name Nat) empty)
                       (concatMap (callOccurrencesOf . snd) defs)
        sccs = tarjanSCCs graph
        cyclic = SortedSet.fromList (concat (filter (\g => length g >= 2) sccs))
                   `union` SortedSet.fromList (filter (\n => contains n (fromMaybe empty (lookup n graph))) (keys graph))
        defOf = SortedMap.fromList defs
        isFun : Name -> Bool
        isFun n = case lookup n defOf of
                       Just (MkRCFun _ _ _ _) => True
                       _ => False
        eligible = SortedSet.fromList $ mapMaybe
                     (\(n, c) => if c == 1 && isFun n && not (contains n cyclic) then Just n else Nothing)
                     (SortedMap.toList callCounts)
    in MkAnalysis graph callCounts eligible (reverse (concat sccs))

------------------------------------------------------------------------
-- Splicing one call site
------------------------------------------------------------------------

mutual
  ||| Every locally-bound id in `e` -- `RLet`'s own `var`, `RConAlt`'s
  ||| own destructured `args`, `RLoop`'s own `loopParams`. Everything
  ||| the callee's own body binds *besides* its top-level params, which
  ||| `spliceCall` renames separately.
  collectBoundIds : RCExp -> List Int
  collectBoundIds (RLet _ var _ value body) = var :: (collectBoundIds value ++ collectBoundIds body)
  collectBoundIds (RCmpCase _ _ _ _ t f) = collectBoundIds t ++ collectBoundIds f
  collectBoundIds (RConCase _ _ alts mDef) = concatMap collectBoundIdsAlt alts ++ maybe [] collectBoundIds mDef
  collectBoundIds (RConstCase _ _ alts mDef) = concatMap collectBoundIdsConstAlt alts ++ maybe [] collectBoundIds mDef
  collectBoundIds (RLoop _ loopParams _ _ body) = map fst loopParams ++ collectBoundIds body
  collectBoundIds (RDup _ _ _ body) = collectBoundIds body
  collectBoundIds (RDrop _ _ body) = collectBoundIds body
  collectBoundIds (RFree _ _ body) = collectBoundIds body
  collectBoundIds (RReleaseReuse _ _ body) = collectBoundIds body
  collectBoundIds (RReuseOffer _ _ _ _ body) = collectBoundIds body
  collectBoundIds (RMemoize _ _ _ body) = collectBoundIds body
  collectBoundIds _ = []

  collectBoundIdsAlt : RConAlt -> List Int
  collectBoundIdsAlt (MkRConAlt _ _ _ as body) = as ++ collectBoundIds body

  collectBoundIdsConstAlt : RConstAlt -> List Int
  collectBoundIdsConstAlt (MkRConstAlt _ body) = collectBoundIds body

||| Builds the renaming from `calleeArgs`'s own top-level param ids
||| onto the actual call arguments, plus a wrapping function for any
||| argument, bound via one `RLet` ahead of the callee's own renamed
||| body.
|||
||| Every argument gets its own fresh id here, even one that's already
||| a bare `RCLoc` -- deliberately never just `insert paramId j ren`
||| directly onto the caller's own local `j`. A loop-converted callee's
||| own `RLoop` commonly reuses its top-level param's own id as a
||| *mutable* loop-carried variable (`Compiler.RC2.Loop`'s own
||| "reuses its own id" case, `Emit.idr`'s own `declareLoopParam`).
||| Aliasing that id directly onto the caller's `j` would let the
||| spliced-in loop reassign the caller's own variable in place --
||| exactly the isolation an ordinary (non-inlined) call already gives
||| for free (the callee's own parameter is always a fresh copy) and
||| this splice must preserve. Found via a real bug: `map (*2) xs`
||| immediately followed by `filter p xs` on the same `xs`, both single-
||| caller-eligible, spliced back to back -- `map`'s own loop consumed
||| the shared variable down to empty before `filter`'s own loop ever
||| ran, since both were renamed onto the very same id.
buildSplice : {auto v : Ref VarId Int} -> FC -> List (Int, Rep, RCLocal) -> Core (Renaming, RCExp -> RCExp)
buildSplice fc [] = pure (empty, id)
buildSplice fc ((paramId, rep, actual) :: rest) = do
    (ren, wrap) <- buildSplice fc rest
    f <- freshVarId
    pure (insert paramId f ren, wrap . RLet fc f rep (RV fc actual))

||| Every id `collectBoundIds` finds, freshened -- so it can never
||| collide with anything, anywhere else in the program.
|||
||| Needed even though `Compiler.RC2.Util`'s own `VarId` counter
||| already makes every id globally unique from the moment it's first
||| assigned: `Compiler.RC2.SpecClosure` builds *several* clones from
||| one shared original body, and only rewrites each clone's own
||| apply-chain/self-call, leaving the rest of that body -- internal
||| ids included -- copied verbatim into every clone. Two such clones
||| therefore legitimately share their own internal ids, harmlessly, as
||| long as each stays its own separate C function (C scopes locals
||| per function). Splicing two of them into the *same* caller breaks
||| that separation -- found via a real bug: two single-caller-eligible
||| clones, each with their own unrelated `let v301 = ...`, both
||| spliced into the same caller produced two C declarations of
||| `var_301` in one function.
freshenBoundIds : {auto v : Ref VarId Int} -> List Int -> Core Renaming
freshenBoundIds [] = pure empty
freshenBoundIds (i :: is) = do
    ren <- freshenBoundIds is
    f <- freshVarId
    pure (insert i f ren)

||| Replace one fully-saturated call to an eligible callee with its own
||| (renamed) body.
spliceCall : {auto v : Ref VarId Int} -> FC -> RCDef -> List RCLocal -> Core RCExp
spliceCall fc (MkRCFun calleeArgs _ _ calleeBody) actualArgs = do
    (paramRen, wrap) <- buildSplice fc (zipArgs calleeArgs actualArgs)
    let paramIds = SortedSet.fromList (map fst calleeArgs)
    internalRen <- freshenBoundIds (filter (\i => not (contains i paramIds)) (collectBoundIds calleeBody))
    let ren = foldl (\acc, (k, val) => insert k val acc) paramRen (SortedMap.toList internalRen)
    pure $ wrap (renameRCExp ren calleeBody)
  where
    zipArgs : List (Int, Rep) -> List RCLocal -> List (Int, Rep, RCLocal)
    zipArgs ((i, r) :: is) (a :: as) = (i, r, a) :: zipArgs is as
    zipArgs _ _ = []
-- Defensive only -- `eligible` (built from `isFun` in `analyse`) never
-- names anything but a `MkRCFun`.
spliceCall _ d _ = pure (RCrash EmptyFC "[rc2] internal: LateInline target wasn't a MkRCFun")

------------------------------------------------------------------------
-- Whole-tree rewrite: replace every eligible call site
------------------------------------------------------------------------

||| Every wrapper/branch node `Compiler.RC2.RC`'s `annotate` and
||| `Compiler.RC2.Loop`'s own passes can already have produced by this
||| point in the pipeline (ownership nodes, `RLoop`, `RMemoize`
||| included -- this pass runs after all of them, see the doc's
||| "Pipeline position"). A call site can sit under any of these, so
||| every one is walked; everything else is a leaf as far as this
||| rewrite is concerned (no `RAppName` can hide inside a bare
||| `RCLocal`).
inlineInto : {auto v : Ref VarId Int} -> SortedMap Name RCDef -> SortedSet Name -> RCExp -> Core RCExp
inlineInto defOf eligible = go
  where
   mutual
    -- `where` clauses aren't implicitly `mutual` in this Idris2 version
    -- -- `go`'s own RConCase/RConstCase cases below need `goMaybe`
    -- (defined after `go` here for readability), so this block needs
    -- to be explicit about it (confirmed empirically: dropping this
    -- reproduces "Undefined name ... goMaybe" even with `goMaybe`
    -- placed textually after every use).
    go : RCExp -> Core RCExp
    go (RAppName fc lazy n args) =
        if contains n eligible
           then case lookup n defOf of
                     Just d => spliceCall fc d args
                     Nothing => pure (RAppName fc lazy n args)
           else pure (RAppName fc lazy n args)
    go (RLet fc var rep value body) = RLet fc var rep <$> go value <*> go body
    go (RCmpCase fc op args postDrop t f) = RCmpCase fc op args postDrop <$> go t <*> go f
    go (RConCase fc sc alts mDef) = RConCase fc sc <$> traverse goAlt alts <*> goMaybe mDef
      where
        goAlt : RConAlt -> Core RConAlt
        goAlt (MkRConAlt n ci tag as body) = MkRConAlt n ci tag as <$> go body
    go (RConstCase fc sc alts mDef) = RConstCase fc sc <$> traverse goConstAlt alts <*> goMaybe mDef
      where
        goConstAlt : RConstAlt -> Core RConstAlt
        goConstAlt (MkRConstAlt c body) = MkRConstAlt c <$> go body
    go (RLoop fc loopParams initial prologueDrop body) = RLoop fc loopParams initial prologueDrop <$> go body
    go (RDup fc v extra body) = RDup fc v extra <$> go body
    go (RDrop fc vs body) = RDrop fc vs <$> go body
    go (RFree fc v body) = RFree fc v <$> go body
    go (RReleaseReuse fc v body) = RReleaseReuse fc v <$> go body
    go (RReuseOffer fc sc dupOnShared dropOnUnique body) = RReuseOffer fc sc dupOnShared dropOnUnique <$> go body
    go (RMemoize fc n rep body) = RMemoize fc n rep <$> go body
    -- RV, RUnderApp, RApp, RCon, ROp, RExtPrim, RPrimVal, RErased,
    -- RCrash, RLoopContinue, RStructGet, RStructSet: no RCExp child to
    -- recurse into. RAppNameRep/RAppFFIInline can't exist yet --
    -- Compiler.RC2.DualABI runs strictly after this pass.
    go e = pure e

    -- Manual case split, not `traverse` -- `Core` has no `Applicative`
    -- instance (`Core.Core`'s own `<$>`/`<*>` above are ad-hoc
    -- functions, not a real instance `Prelude.traverse` could resolve
    -- against), so `traverse`'s generic `Maybe` case doesn't apply.
    goMaybe : Maybe RCExp -> Core (Maybe RCExp)
    goMaybe Nothing = pure Nothing
    goMaybe (Just e) = Just <$> go e

------------------------------------------------------------------------
-- Whole-program entry point
------------------------------------------------------------------------

||| One pass over the whole program. See the doc's "Eligibility"
||| section for why `processOrder` (not `defs`'s own order) is used --
||| a chain of single-caller callees collapses fully in this one call.
export
applyLateInline : {auto v : Ref VarId Int} -> List (Name, RCDef) -> Core (List (Name, RCDef))
applyLateInline defs = do
    let an = analyse defs
    final <- goOrder an.eligible an.processOrder (SortedMap.fromList defs)
    pure $ map (\(n, d) => (n, fromMaybe d (lookup n final))) defs
  where
    goOrder : SortedSet Name -> List Name -> SortedMap Name RCDef -> Core (SortedMap Name RCDef)
    goOrder eligible [] defOf = pure defOf
    goOrder eligible (n :: rest) defOf = do
        defOf' <- case lookup n defOf of
                       Just (MkRCFun args retRep isWorker body) => do
                           body' <- inlineInto defOf eligible body
                           pure (insert n (MkRCFun args retRep isWorker body') defOf)
                       Just (MkRCError body) => do
                           body' <- inlineInto defOf eligible body
                           pure (insert n (MkRCError body') defOf)
                       _ => pure defOf
        goOrder eligible rest defOf'
