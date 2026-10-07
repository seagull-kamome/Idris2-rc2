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
-- via idris2rc2_dup_n. Runs right after DeadCode (Compiler.RC2.DeadVars
-- is the only stage after this one, right before Emit), since later passes
-- (Compiler.RC2.Loop's wrapInvariantDups/dupInvariantBoxed,
-- Compiler.RC2.ConAltNative's wrapNDups) are themselves what NEWLY
-- introduces most of the individual-adjacent-RDup shapes this pass
-- targets -- running earlier would miss everything those later passes
-- go on to construct.
--
-- Running last also makes this the right place for the complementary
-- peephole, `cancelDupDrop`: an `RDup` whose own local is released
-- again by an `RDrop` in the same refcount-only run, with nothing in
-- between that could observe the count.

import Compiler.RC2.Emit.Util
import Compiler.RC2.RCExp

import Core.FC
import Core.TT

import Data.List
import Data.Nat
import Data.SortedMap
import Data.SortedSet
import Data.Vect

%default covering

||| Removes one occurrence of `v` from the first `RDrop` reachable
||| through a contiguous run of refcount-only nodes (`RDup`/`RDrop` and
||| nothing else), or `Nothing` when the run holds no such drop.
takeDropInRun : RCLocal -> RCExp -> Maybe RCExp
takeDropInRun v (RDup fc w extra body) = RDup fc w extra <$> takeDropInRun v body
takeDropInRun v (RDrop fc vs body) =
    if elem v vs
       then Just (case delete v vs of
                       []  => body
                       vs' => RDrop fc vs' body)
       else RDrop fc vs <$> takeDropInRun v body
takeDropInRun _ _ = Nothing

||| The locals bound with a native `Rep` (a parameter, a `let`, a loop
||| parameter): no reference count, never named by a `postDrop`.
nativeBound : List (Int, Rep) -> RCExp -> SortedSet Int
nativeBound args body = union (fromList (mapMaybe nativeParam args)) (go body)
  where
    nativeParam : (Int, Rep) -> Maybe Int
    nativeParam (_, RBoxed) = Nothing
    nativeParam (i, _) = Just i

    go : RCExp -> SortedSet Int
    go e = let here = case e of
                           RLet _ x rep _ _ => maybe empty singleton (nativeParam (x, rep))
                           RLoop _ ps _ _ _ => fromList (mapMaybe nativeParam ps)
                           _ => empty
           in foldl (\acc, c => union acc (go c)) here (children e)

||| For a call (`callRep`, FFI inline): every boxed local operand is only
||| read, each occurrence in `args` released by its own `postDrop` entry.
||| An operand the call consumes (a callee that takes ownership) is not
||| in `postDrop`, and then the callee may free it -- and a field of it
||| -- while still reading `v`, which is exactly what a `dup v` in front
||| guards against.
readsOnly : SortedSet Int -> List RCLocal -> List RCLocal -> Bool
readsOnly ns args pd = all ok args
  where
    occurrences : RCLocal -> List RCLocal -> Nat
    occurrences x xs = length (filter (== x) xs)

    ok : RCLocal -> Bool
    ok x@(RCLoc i) = contains i ns || occurrences x args <= occurrences x pd
    ok _ = True

||| The `postDrop` list of the first node after a run of `RDup`s, with
||| the function that puts a changed list back, or `Nothing` unless that
||| node only READS its operands: an `op` (not a reuse-consuming one --
||| `Emit` skips its `postDrop` because the runtime primitive itself
||| consumes every operand, so there the `dup` is a real reference
||| handed over), an `extprim`, a comparison, or a call all of whose
||| operands are read-only (`readsOnly`). Only `RDup` is passed over -- an
||| `RDrop`/`RFree` could release a parent of the cancelled local, whose
||| destruction would then free it while the node still reads it -- and
||| the node may be the value of a `let` whose own `RDup`s lead it,
||| unless that `let` is `RInlineNative` (its node is spliced at the one
||| use site, possibly past another consumer of the local).
findPostDrop : SortedSet Int -> RCExp -> Maybe (List RCLocal, List RCLocal -> RCExp)
findPostDrop ns (RDup fc w extra body) =
    (\(pd, set) => (pd, \pd' => RDup fc w extra (set pd'))) <$> findPostDrop ns body
findPostDrop ns (RLet fc x rep value body) =
    case rep of
         RInlineNative _ => Nothing
         _ => (\(pd, set) => (pd, \pd' => RLet fc x rep (set pd') body)) <$> findPostDrop ns value
findPostDrop ns (ROp fc Nothing f args pd) =
    if isReuseConsumingOp f || not (readsOnly ns (toList args) pd) then Nothing
       else Just (pd, \pd' => ROp fc Nothing f args pd')
findPostDrop ns (RExtPrim fc Nothing n args pd) =
    if readsOnly ns args pd then Just (pd, \pd' => RExtPrim fc Nothing n args pd') else Nothing
findPostDrop ns (RAppNameRep fc n reps ret pd args) =
    if readsOnly ns args pd then Just (pd, \pd' => RAppNameRep fc n reps ret pd' args) else Nothing
findPostDrop ns (RAppFFIInline fc ccs fargs ret pd args) =
    if readsOnly ns args pd then Just (pd, \pd' => RAppFFIInline fc ccs fargs ret pd' args) else Nothing
findPostDrop ns (RCmpCase fc o args pd t f) =
    if readsOnly ns (toList args) pd then Just (pd, \pd' => RCmpCase fc o args pd' t f) else Nothing
findPostDrop _ _ = Nothing

spanDups : RCExp -> (List (FC, RCLocal, Nat), RCExp)
spanDups (RDup fc v extra body) = let (ds, rest) = spanDups body in ((fc, v, extra) :: ds, rest)
spanDups e = ([], e)

dropN : Nat -> RCLocal -> List RCLocal -> List RCLocal
dropN Z _ pd = pd
dropN (S k) v pd = dropN k v (delete v pd)

||| Cancels the leading run of `RDup`s of `e` against the `postDrop` of
||| the read-only node right after it (`findPostDrop`), or `Nothing` when
||| no entry cancels. `postDrop` runs AFTER the node's own evaluation, so
||| `dup v; node ... postDrop=[v]` is `+1`, read, `-1`: a no-op pair, as
||| nothing between them can observe or consume the extra reference. A
||| local with `extra + 1` references and `m` entries in `postDrop`
||| cancels `min (extra + 1) m` of each. The whole run is judged against
||| the ORIGINAL list in one step: `readsOnly` asks whether the node
||| consumes any operand, which a list already shortened by an earlier
||| cancellation would answer wrongly. See `rc2/doc/reading-the-ir.md`
||| section 6.
cancelRun : SortedSet Int -> RCExp -> Maybe RCExp
cancelRun ns e =
    let (dups, rest) = spanDups e
    in case findPostDrop ns rest of
            Nothing => Nothing
            Just (pd, set) =>
                let (kept, pd') = foldl step ([], pd) dups
                in if length pd' == length pd then Nothing
                      else Just (foldl (\acc, (fc, v, x) => RDup fc v x acc) (set pd') kept)
  where
    -- `extra` is the count MINUS one.
    step : (List (FC, RCLocal, Nat), List RCLocal) -> (FC, RCLocal, Nat) -> (List (FC, RCLocal, Nat), List RCLocal)
    step (kept, pd) d@(fc, v, x) =
        let k = min (S x) (length (filter (== v) pd))
        in if k == 0 then (d :: kept, pd)
           else if k == S x then (kept, dropN k v pd)
           else ((fc, v, minus x k) :: kept, dropN k v pd)

||| Renames `x` to `w` in the first `RDrop` naming `x` through a run of
||| `RDup`/`RDrop`, for `cancelDupDrop`'s alias case: `let x = w` just
||| names the same object again.
renameAliasDrop : RCLocal -> RCLocal -> RCExp -> Maybe RCExp
renameAliasDrop x w (RDup fc v extra body) =
    if v == x then Nothing else RDup fc v extra <$> renameAliasDrop x w body
renameAliasDrop x w (RDrop fc vs body) =
    if elem x vs
       then Just (RDrop fc (map (\v => if v == x then w else v) vs) body)
       else RDrop fc vs <$> renameAliasDrop x w body
renameAliasDrop _ _ _ = Nothing

||| Cancels each `RDup` against a later `RDrop` of the same local
||| within one contiguous run of refcount-only nodes. Such a run holds
||| nothing that could observe the count between the two -- no call, no
||| uniqueness check (`RReuseOffer` deliberately ends a run) -- so the
||| `+1`/`-1` pair is pure overhead: two atomic RMWs buying nothing.
||| Likewise against the `postDrop` entry of the read-only node right
||| after the dups (`cancelRun`).
||| Same region shape as `collectDupCounts`, and run BEFORE it: doing
||| it afterwards would leave the merged `extra` re-inflating exactly
||| what was just cancelled.
|||
||| Also removes an alias `let x = w` (boxed `w`) whose first mention is
||| a `drop`, by dropping `w` there instead (`renameAliasDrop`): the
||| `let` only names the same object again, and a `dup w` that led it
||| then cancels against that drop. `ns` (`nativeBound`) keeps this off a
||| native `w`, which the boxed `let` would box into a new object.
cancelDupDrop : SortedSet Int -> RCExp -> RCExp
cancelDupDrop ns e@(RDup fc v extra body) =
    case cancelRun ns e of
         Just e' => cancelDupDrop ns e'
         Nothing => case takeDropInRun v body of
                         Just body' => cancelled fc v extra body'
                         Nothing => RDup fc v extra (cancelDupDrop ns body)
  where
    -- `extra` is the count MINUS one, so a plain `RDup` (extra =
    -- Z) is fully cancelled and disappears.
    cancelled : FC -> RCLocal -> Nat -> RCExp -> RCExp
    cancelled fc v Z body = cancelDupDrop ns body
    cancelled fc v (S k) body = cancelDupDrop ns (RDup fc v k body)
cancelDupDrop ns e@(RLet fc var rep value body) =
    case (rep, value) of
         (RBoxed, RV _ w@(RCLoc j)) =>
             if contains j ns then plain
             else case renameAliasDrop (RCLoc var) w body of
                       Just body' => cancelDupDrop ns body'
                       Nothing => plain
         _ => plain
  where
    plain : RCExp
    plain = RLet fc var rep (cancelDupDrop ns value) (cancelDupDrop ns body)
cancelDupDrop ns (RDrop fc vs body) = RDrop fc vs (cancelDupDrop ns body)
cancelDupDrop ns (RFree fc v body) = RFree fc v (cancelDupDrop ns body)
cancelDupDrop ns (RReleaseReuse fc v body) = RReleaseReuse fc v (cancelDupDrop ns body)
cancelDupDrop ns (RReuseOffer fc sc dupOnShared dropOnUnique body) =
    RReuseOffer fc sc dupOnShared dropOnUnique (cancelDupDrop ns body)
-- Branch/loop children are separate regions with their own
-- `mergeDupsExp` below, which cancels them again on its own way
-- through -- harmless (this is idempotent), and it makes this function
-- usable standalone over a whole definition, which
-- `applyCancelDupDrop` needs.
cancelDupDrop ns (RCmpCase fc op args postDrop t f) =
    RCmpCase fc op args postDrop (cancelDupDrop ns t) (cancelDupDrop ns f)
cancelDupDrop ns (RConCase fc sc alts mDef) =
    RConCase fc sc (map (\(MkRConAlt n ci tag as body) => MkRConAlt n ci tag as (cancelDupDrop ns body)) alts)
      (map (cancelDupDrop ns) mDef)
cancelDupDrop ns (RConstCase fc sc alts mDef) =
    RConstCase fc sc (map (\(MkRConstAlt c body) => MkRConstAlt c (cancelDupDrop ns body)) alts)
      (map (cancelDupDrop ns) mDef)
cancelDupDrop ns (RLoop fc loopParams initial prologueDrop body) =
    RLoop fc loopParams initial prologueDrop (cancelDupDrop ns body)
cancelDupDrop ns (RMemoize fc n rep body) = RMemoize fc n rep (cancelDupDrop ns body)
cancelDupDrop _ e = e

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
  rewriteRegion : (ns : SortedSet Int) -> (counts : SortedMap RCLocal Nat) -> (done : SortedSet RCLocal)
               -> RCExp -> (SortedSet RCLocal, RCExp)
  rewriteRegion ns counts done (RLet fc var rep value body) =
      let (done1, value') = rewriteRegion ns counts done  value
          (done2, body')  = rewriteRegion ns counts done1 body
      in (done2, RLet fc var rep value' body')
  rewriteRegion ns counts done (RDup fc v extra body) =
      if contains v done
         then rewriteRegion ns counts done body
         else case lookup v counts of
                   Just cnt =>
                       if cnt == S extra
                          then let (done', body') = rewriteRegion ns counts done body
                               in (done', RDup fc v extra body')
                          else let (done2, body') = rewriteRegion ns counts (insert v done) body
                               in (done2, RDup fc v (pred cnt) body')
                   Nothing => -- unreachable: this node's own occurrence is always
                              -- counted by collectDupCounts on this same region
                       let (done', body') = rewriteRegion ns counts done body
                       in (done', RDup fc v extra body')
  rewriteRegion ns counts done (RDrop fc vs body) =
      let (done', body') = rewriteRegion ns counts done body in (done', RDrop fc vs body')
  rewriteRegion ns counts done (RFree fc v body) =
      let (done', body') = rewriteRegion ns counts done body in (done', RFree fc v body')
  rewriteRegion ns counts done (RReleaseReuse fc v body) =
      let (done', body') = rewriteRegion ns counts done body in (done', RReleaseReuse fc v body')
  rewriteRegion ns counts done (RReuseOffer fc sc dupOnShared dropOnUnique body) =
      let (done', body') = rewriteRegion ns counts done body
      in (done', RReuseOffer fc sc dupOnShared dropOnUnique body')
  rewriteRegion ns counts done (RCmpCase fc op args postDrop t f) =
      (done, RCmpCase fc op args postDrop (mergeDupsExp ns t) (mergeDupsExp ns f))
  rewriteRegion ns counts done (RConCase fc sc alts mDef) =
      (done, RConCase fc sc
               (map (\(MkRConAlt n ci tag as body) => MkRConAlt n ci tag as (mergeDupsExp ns body)) alts)
               (map (mergeDupsExp ns) mDef))
  rewriteRegion ns counts done (RConstCase fc sc alts mDef) =
      (done, RConstCase fc sc
               (map (\(MkRConstAlt c body) => MkRConstAlt c (mergeDupsExp ns body)) alts)
               (map (mergeDupsExp ns) mDef))
  rewriteRegion ns counts done (RLoop fc loopParams initial prologueDrop body) =
      (done, RLoop fc loopParams initial prologueDrop (mergeDupsExp ns body))
  rewriteRegion ns counts done e = (done, e)

  ||| Entry point for one fresh region: collects this region's own dup
  ||| counts, then rewrites it top-to-bottom starting from an empty
  ||| `done` set. Every RConCase/RConstCase/RCmpCase/RLoop child
  ||| encountered along the way recurses back into this same function
  ||| as an entirely independent region (see `rewriteRegion`'s own
  ||| handling of those four constructors).
  export
  mergeDupsExp : SortedSet Int -> RCExp -> RCExp
  mergeDupsExp ns e = let e' = cancelDupDrop ns e
                       in snd (rewriteRegion ns (collectDupCounts e') empty e')

||| `cancelDupDrop` alone over one whole definition, with no re-merge.
||| Run once more after `Compiler.RC2.DeadVars`: erasing a dead `RLet`
||| can leave a `dup` and a `drop` of the same local adjacent that
||| weren't when this module's own pass ran, and nothing afterwards
||| would notice. Measured over a whole idris2-lsp build, that is a
||| couple of dozen pairs -- small, but there is no reason to ship
||| them, and `rc2/tests/Test79DupMerge`'s own verify.sh check would
||| otherwise have to tolerate a moving target.
export
applyCancelDupDrop : RCDef -> RCDef
applyCancelDupDrop (MkRCFun args retRep isWorker body) = MkRCFun args retRep isWorker (cancelDupDrop (nativeBound args body) body)
applyCancelDupDrop (MkRCError body) = MkRCError (cancelDupDrop (nativeBound [] body) body)
applyCancelDupDrop d@(MkRCCon _ _ _) = d
applyCancelDupDrop d@(MkRCForeign _ _ _) = d

||| Apply dup-merging to one top-level definition.
export
applyDupMerge : RCDef -> RCDef
applyDupMerge (MkRCFun args retRep isWorker body) = MkRCFun args retRep isWorker (mergeDupsExp (nativeBound args body) body)
applyDupMerge (MkRCError body) = MkRCError (mergeDupsExp (nativeBound [] body) body)
applyDupMerge d@(MkRCCon _ _ _) = d
applyDupMerge d@(MkRCForeign _ _ _) = d
