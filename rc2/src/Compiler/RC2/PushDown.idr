||| Dup/drop push-down: a run of `dup`/`drop` nodes that sits right in
||| front of a `case`, or of a `let` whose value is one, is moved into the
||| head of every arm, where a `dup` meets the `drop` of the same local
||| that the arm opens with and the pair is cancelled. This is what is
||| left of the lint's pattern A (a `dup` above a `case` that some arm
||| cancels) for the adjacent runs;
||| see `rc2/doc/pushdown.md` for the soundness argument, the cases it
||| deliberately leaves alone, and the measurements. Runs right after
||| dead-code elimination and before `DupMerge`, so it sees the final
||| shape of every producer (`Reuse`'s field dups, `LateInline`'s spliced
||| bodies, `Loop`'s and `DualABI`'s dups) and leaves the leftovers to
||| `DupMerge`'s own peepholes. Disable with `--directive nopushdown`.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Compiler.RC2.PushDown

import Compiler.RC2.RCExp

import Core.FC

import Data.List
import Data.Maybe
import Data.SortedSet
import Data.Vect

%default covering

||| One node of a refcount-only run. A `DupOp` holds the dup COUNT
||| (`RDup`'s `extra` plus one).
data RcOp = DupOp FC LocalId Nat
          | DropOp FC (List LocalId)

||| The leading refcount-only nodes of `e` and what follows them.
spanRun : RCExp -> (List RcOp, RCExp)
spanRun (RDup fc v extra body) = let (ops, rest) = spanRun body in (DupOp fc v (S extra) :: ops, rest)
spanRun (RDrop fc vs body) = let (ops, rest) = spanRun body in (DropOp fc vs :: ops, rest)
spanRun e = ([], e)

rebuild : List RcOp -> RCExp -> RCExp
rebuild [] e = e
rebuild (DupOp fc v n :: ops) e = RDup fc v (pred n) (rebuild ops e)
rebuild (DropOp fc vs :: ops) e = RDrop fc vs (rebuild ops e)

||| Dup and drop operations in a run, counted one per reference.
opCount : List RcOp -> Nat
opCount = sum . map count
  where
    count : RcOp -> Nat
    count (DupOp _ _ n) = n
    count (DropOp _ vs) = length vs

dropsOf : List RcOp -> List LocalId
dropsOf = concatMap (\o => case o of
                                DropOp _ vs => vs
                                _ => [])

addDup : List (FC, LocalId, Nat) -> RcOp -> List (FC, LocalId, Nat)
addDup acc (DupOp fc v n) =
    if any (\(_, w, _) => w == v) acc
       then map (\(f, w, m) => if w == v then (f, w, m + n) else (f, w, m)) acc
       else acc ++ [(fc, v, n)]
addDup acc _ = acc

removeN : Nat -> LocalId -> List LocalId -> List LocalId
removeN Z _ xs = xs
removeN (S k) v xs = removeN k v (delete v xs)

||| The canonical form of a refcount-only run, and how many `dup`/`drop`
||| pairs cancelled in it: every `dup` first, then one `drop`. A local
||| `dup`'d more than once comes before those `dup`'d once: Emit writes its
||| `idris2rc2_dup_n` as a call of its own, which would split their batch.
||| Moving a `dup` earlier is safe (fewer objects have died by then) and so
||| is moving a `drop` later (an object only lives longer), so reordering a
||| run this way never frees anything early; and once every `dup` precedes
||| every `drop`, a `dup v` and a `drop v` cancel whatever sits between
||| them, even the `drop` of a parent that owns `v`.
normalize : List RcOp -> (Nat, List RcOp)
normalize ops =
    let (cancelled, dups, drops) = foldl cancel (0, [], dropsOf ops) (foldl addDup [] ops)
        dropFC = fromMaybe emptyFC (head' (mapMaybe (\o => case o of
                                                              DropOp fc _ => Just fc
                                                              _ => Nothing) ops))
    in (cancelled, map (\(fc, v, n) => DupOp fc v n) (uncurry (++) (partition (\(_, _, n) => n > 1) (reverse dups)))
                   ++ (if null drops then [] else [DropOp dropFC drops]))
  where
    cancel : (Nat, List (FC, LocalId, Nat), List LocalId) -> (FC, LocalId, Nat)
          -> (Nat, List (FC, LocalId, Nat), List LocalId)
    cancel (c, ds, drops) (fc, v, n) =
        let k = min n (length (filter (== v) drops))
        in (c + k, if n > k then (fc, v, minus n k) :: ds else ds, removeN k v drops)

||| The locals a `case` reads at dispatch, its arms, and a function that
||| puts new arm bodies back (same order: alternatives, then the default).
||| A comparison with a `postDrop` is left alone: its drops run before the
||| arms and could release the parent of a `dup`'d local we would be moving
||| past them.
caseParts : RCExp -> Maybe (List RCLocal, List RCExp, List RCExp -> RCExp)
caseParts (RConCase fc sc alts mDef) =
    Just ([sc], map (\(MkRConAlt _ _ _ _ b) => b) alts ++ toList mDef, put)
  where
    put : List RCExp -> RCExp
    put bs =
        let (altBodies, defBodies) = splitAt (length alts) bs
        in RConCase fc sc (zipWith (\(MkRConAlt n ci tag as _), b => MkRConAlt n ci tag as b) alts altBodies)
                          (case (mDef, defBodies) of
                                (Just _, d :: _) => Just d
                                _ => Nothing)
caseParts (RConstCase fc sc alts mDef) =
    Just ([sc], map (\(MkRConstAlt _ b) => b) alts ++ toList mDef, put)
  where
    put : List RCExp -> RCExp
    put bs =
        let (altBodies, defBodies) = splitAt (length alts) bs
        in RConstCase fc sc (zipWith (\(MkRConstAlt c _), b => MkRConstAlt c b) alts altBodies)
                            (case (mDef, defBodies) of
                                  (Just _, d :: _) => Just d
                                  _ => Nothing)
caseParts e@(RCmpCase fc op args [] t f) =
    Just (toList args, [t, f], \bs => case bs of
                                           [t', f'] => RCmpCase fc op args [] t' f'
                                           _ => e)
caseParts (RLet fc x rep value body) =
    case rep of
         -- Its value is spliced where `x` is used, so it runs after `body` began.
         RInlineNative _ => Nothing
         _ => (\(scruts, arms, put) => (scruts, arms, \bs => RLet fc x rep (put bs) body)) <$> caseParts value
caseParts _ = Nothing

||| Move the run `ops` into every arm of the `case` `e` when that cancels
||| something and the static count of `dup`/`drop` operations does not grow.
|||
||| Each arm gets `ops ++ its own leading run`, normalized. The delay is
||| sound: the dispatch changes no reference count, so every operation of
||| the run just happens a moment later, in the same order relative to
||| everything the arm does. Only the arm's own leading run is searched for
||| the cancelling `drop` -- nothing that could observe a count sits between.
tryPush : List RcOp -> RCExp -> Maybe RCExp
tryPush ops e = do
    (scruts, arms, put) <- caseParts e
    let (_, run) = normalize ops
    -- A `drop` of what the dispatch reads is never moved past it.
    guard (not (any (\s => any (\i => RCLoc i == s) (dropsOf run)) scruts))
    let parts = map (\b => let (q, rest) = spanRun b in (snd (normalize q), rest)) arms
    let results = map (\(q, _) => normalize (run ++ q)) parts
    let cancelled = the Nat (sum (map fst results))
    let before = the Nat (opCount run + sum (map (opCount . fst) parts))
    let after = the Nat (sum (map (opCount . snd) results))
    guard (cancelled > 0 && after <= before)
    pure (put (zipWith (\(_, o), (_, rest) => rebuild o rest) results parts))

pushDownExp : RCExp -> RCExp
pushDownExp e =
    case spanRun e of
         ([], _) => mapChildren pushDownExp e
         (ops, rest) => case tryPush ops rest of
                             Just pushed => mapChildren pushDownExp pushed
                             Nothing => rebuild ops (mapChildren pushDownExp rest)

||| The calls `Emit` writes for a run: consecutive plain dups, or drops,
||| become one batched call per `Emit.Util.pendingLines`, and a dup of a
||| count above one is a call of its own that ends a batch.
emittedCalls : List RcOp -> Nat
emittedCalls = go Nothing 0
  where
    batched : Nat -> Nat
    batched n = if n <= 2 then n
                else if n <= 6 || n == 9 then 1
                else if n <= 8 then 2
                else 1 + batched (minus n 6)

    flush : Maybe Bool -> Nat -> Nat
    flush Nothing _ = 0
    flush (Just _) n = batched n

    go : Maybe Bool -> Nat -> List RcOp -> Nat
    go k n [] = flush k n
    go k n (DupOp _ _ c :: ops) =
        if c == 1
           then if k == Just True then go k (S n) ops else flush k n + go (Just True) 1 ops
           else flush k n + 1 + go Nothing 0 ops
    go k n (DropOp _ vs :: ops) =
        if k == Just False then go k (n + length vs) ops else flush k n + go (Just False) (length vs) ops

||| Every refcount-only run of `e` in its canonical form when that cancels
||| a pair or lets `Emit` batch it into fewer calls
||| (`rc2/doc/batched-drops.md`). A run that gains nothing keeps its order
||| (`rc2/doc/pushdown.md`, "Canonical runs").
normalizeRuns : RCExp -> RCExp
normalizeRuns e =
    let (ops, rest0) = spanRun e
        (hoisted, rest) = hoistDups rest0
        run = ops ++ hoisted
        (cancelled, run') = normalize run
        kept = if cancelled > 0 || emittedCalls run' < emittedCalls run then run' else run
    in rebuild kept (mapChildren normalizeRuns rest)
  where
    dupCounts : List RcOp -> List (LocalId, Nat)
    dupCounts = map (\(_, v, n) => (v, n)) . foldl addDup []

    takeDups : List (LocalId, Nat) -> List RcOp -> List RcOp
    takeDups _ [] = []
    takeDups hs (DupOp fc v n :: ops) =
        let t = min n (fromMaybe 0 (lookup v hs))
            hs' = map (\(w, m) => if w == v then (w, minus m t) else (w, m)) hs
        in (if n == t then [] else [DupOp fc v (minus n t)]) ++ takeDups hs' ops
    takeDups hs (op :: ops) = op :: takeDups hs ops

    -- The dups that lead every arm of the `case` `c` (any number of times,
    -- the fewest of them), of locals bound outside it, moved in front of
    -- it: one copy instead of one per arm, and every path makes as many as
    -- before. A drop is not moved: before the dispatch it could free a
    -- parent of what the dispatch reads.
    hoistDups : RCExp -> (List RcOp, RCExp)
    hoistDups c = fromMaybe ([], c) $ do
        (_, arms, put) <- caseParts c
        guard (length arms >= 2)
        let runs = map spanRun arms
        let common = case map (dupCounts . fst) runs of
                          r :: rs => mapMaybe (\(v, n) => do
                                                   ms <- traverse (lookup v) rs
                                                   pure (v, foldl min n ms)) r
                          [] => []
        -- `freeLocalsR` walks all of `c`: only for the few with a common dup.
        guard (not (null common))
        let free = freeLocalsR c
        let hs = filter (\(v, _) => contains (RCLoc v) free) common
        guard (not (null hs))
        pure (map (\(v, n) => DupOp emptyFC v n) hs,
              put (map (\(ops, rest) => rebuild (takeDups hs ops) rest) runs))

||| `normalizeRuns` over one top-level definition.
export
applyNormalizeRuns : RCDef -> RCDef
applyNormalizeRuns (MkRCFun args retRep isWorker body) = MkRCFun args retRep isWorker (normalizeRuns body)
applyNormalizeRuns (MkRCError body) = MkRCError (normalizeRuns body)
applyNormalizeRuns d@(MkRCCon _ _ _) = d
applyNormalizeRuns d@(MkRCForeign _ _ _) = d

||| Apply the push-down to one top-level definition.
export
applyPushDown : RCDef -> RCDef
applyPushDown (MkRCFun args retRep isWorker body) = MkRCFun args retRep isWorker (pushDownExp body)
applyPushDown (MkRCError body) = MkRCError (pushDownExp body)
applyPushDown d@(MkRCCon _ _ _) = d
applyPushDown d@(MkRCForeign _ _ _) = d
