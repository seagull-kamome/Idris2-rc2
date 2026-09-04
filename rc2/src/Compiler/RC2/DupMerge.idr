module Compiler.RC2.DupMerge

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Merges several individual `RDup` nodes targeting the same variable
-- within one straight-line region (no intervening branch/loop --
-- `annotate` computes each branch's own dup/drop bookkeeping
-- independently, so merging across a branch boundary would
-- over-increment a refcount on whichever branch is actually NOT taken
-- at runtime, a permanent leak -- see RC.idr's own RConCase/RConstCase
-- annotate cases, which pass the identical `owned` set to every alt
-- independently rather than accumulating across them) into one RDup
-- with a higher `extra`, trading N atomic increments (each paying its
-- own conditional-branch-plus-atomic-add cost) for a single batched one
-- via idris2rc2_dup_n. Runs as the pipeline's very last stage, right
-- before Emit (after DeadCode), since later passes
-- (Compiler.RC2.Loop's wrapInvariantDups/dupInvariantBoxed,
-- Compiler.RC2.ConAltNative's wrapNDups) are themselves what NEWLY
-- introduces most of the individual-adjacent-RDup shapes this pass
-- targets -- running earlier would miss everything those later passes
-- go on to construct.

import Compiler.RC2.RCExp

import Core.FC

import Data.Nat
import Data.SortedMap
import Data.SortedSet

%default covering

||| Collects, for every RCLocal targeted by at least one RDup anywhere
||| within `e`'s own straight-line region (never descending into a
||| RConCase/RConstCase/RCmpCase/RLoop's own children -- those are
||| independent regions, scanned separately, see `mergeDupsExp`), the
||| TOTAL increment count (`S extra` summed across every such RDup node
||| targeting that same local).
collectDupCounts : RCExp -> SortedMap RCLocal Nat
collectDupCounts (RLet _ _ _ value body) =
    mergeWith (+) (collectDupCounts value) (collectDupCounts body)
collectDupCounts (RDup _ v extra body) =
    insertWith (+) v (S extra) (collectDupCounts body)
collectDupCounts (RDrop _ _ body) = collectDupCounts body
collectDupCounts (RFree _ _ body) = collectDupCounts body
collectDupCounts (RReleaseReuse _ _ body) = collectDupCounts body
collectDupCounts (RReuseOffer _ _ _ _ body) = collectDupCounts body
collectDupCounts _ = empty

mutual
  ||| Rewrites `e`'s own region using `counts` (from `collectDupCounts`
  ||| on this SAME region) and `done` (locals whose merged RDup this
  ||| walk has already placed, so later occurrences within the same
  ||| region get spliced out entirely rather than re-checked). Returns
  ||| the updated `done` alongside the rewritten expression.
  |||
  ||| For a `RDup` targeting a local already in `done`: delete the node
  ||| (its own inner `body` continuation is kept, spliced into its own
  ||| former position) -- this is a later, now-redundant occurrence.
  ||| Otherwise, this is the FIRST occurrence of that local's own RDup
  ||| within the region: if `counts` says its own total is exactly `S
  ||| extra` already (only one RDup for this local exists in the whole
  ||| region), leave it untouched (no wasted rewrite for the common
  ||| case of a variable dup'd only once). Otherwise, bump this node's
  ||| own `extra` up to `pred total` (so its own actual increment count,
  ||| `S (pred total)`, equals the region's full total for this local),
  ||| record the local in `done`, and continue.
  rewriteRegion : (counts : SortedMap RCLocal Nat) -> (done : SortedSet RCLocal)
               -> RCExp -> (SortedSet RCLocal, RCExp)
  rewriteRegion counts done (RLet fc var rep value body) =
      let (done1, value') = rewriteRegion counts done  value
          (done2, body')  = rewriteRegion counts done1 body
      in (done2, RLet fc var rep value' body')
  rewriteRegion counts done (RDup fc v extra body) =
      if contains v done
         then rewriteRegion counts done body
         else case lookup v counts of
                   Just cnt =>
                       if cnt == S extra
                          then let (done', body') = rewriteRegion counts done body
                               in (done', RDup fc v extra body')
                          else let (done2, body') = rewriteRegion counts (insert v done) body
                               in (done2, RDup fc v (pred cnt) body')
                   Nothing => -- unreachable: this node's own occurrence is always
                              -- counted by collectDupCounts on this same region
                       let (done', body') = rewriteRegion counts done body
                       in (done', RDup fc v extra body')
  rewriteRegion counts done (RDrop fc vs body) =
      let (done', body') = rewriteRegion counts done body in (done', RDrop fc vs body')
  rewriteRegion counts done (RFree fc v body) =
      let (done', body') = rewriteRegion counts done body in (done', RFree fc v body')
  rewriteRegion counts done (RReleaseReuse fc v body) =
      let (done', body') = rewriteRegion counts done body in (done', RReleaseReuse fc v body')
  rewriteRegion counts done (RReuseOffer fc sc dupOnShared dropOnUnique body) =
      let (done', body') = rewriteRegion counts done body
      in (done', RReuseOffer fc sc dupOnShared dropOnUnique body')
  rewriteRegion counts done (RCmpCase fc op args postDrop t f) =
      (done, RCmpCase fc op args postDrop (mergeDupsExp t) (mergeDupsExp f))
  rewriteRegion counts done (RConCase fc sc alts mDef) =
      (done, RConCase fc sc
               (map (\(MkRConAlt n ci tag as body) => MkRConAlt n ci tag as (mergeDupsExp body)) alts)
               (map mergeDupsExp mDef))
  rewriteRegion counts done (RConstCase fc sc alts mDef) =
      (done, RConstCase fc sc
               (map (\(MkRConstAlt c body) => MkRConstAlt c (mergeDupsExp body)) alts)
               (map mergeDupsExp mDef))
  rewriteRegion counts done (RLoop fc loopParams initial prologueDrop body) =
      (done, RLoop fc loopParams initial prologueDrop (mergeDupsExp body))
  rewriteRegion counts done e = (done, e)

  ||| Entry point for one fresh region: collects this region's own dup
  ||| counts, then rewrites it top-to-bottom starting from an empty
  ||| `done` set. Every RConCase/RConstCase/RCmpCase/RLoop child
  ||| encountered along the way recurses back into this same function
  ||| as an entirely independent region (see `rewriteRegion`'s own
  ||| handling of those four constructors).
  export
  mergeDupsExp : RCExp -> RCExp
  mergeDupsExp e = snd (rewriteRegion (collectDupCounts e) empty e)

||| Apply dup-merging to one top-level definition.
export
applyDupMerge : RCDef -> RCDef
applyDupMerge (MkRCFun args retRep isWorker body) = MkRCFun args retRep isWorker (mergeDupsExp body)
applyDupMerge (MkRCError body) = MkRCError (mergeDupsExp body)
applyDupMerge d@(MkRCCon _ _ _) = d
applyDupMerge d@(MkRCForeign _ _ _) = d
