||| Whole-program `RCExp` inlining, run after `Loop`/`MutualLoop`: splices
||| a callee's body into its call site when that is the only place in the
||| program that calls it. Named for the pass, not the criterion, so the
||| criterion can widen. Design, the cycle-exclusion argument and why
||| every callee id is renamed: `rc2/doc/inlining.md`, "Criterion B,
||| revisited". Disable with `--directive nolateinline`.
module Compiler.RC2.LateInline

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Compiler.RC2.DeadCode
import Compiler.RC2.DualABI
import Compiler.RC2.Loop
import Compiler.RC2.Rewrite
import Compiler.RC2.MutualLoop
import Compiler.RC2.RCExp
import Compiler.RC2.Types
import Compiler.RC2.Util

import Core.Context.Log


import Data.List1
import Data.SortedMap
import Data.SortedSet

%default covering

------------------------------------------------------------------------
-- Whole-program call-site counting + call graph (cycle exclusion)
------------------------------------------------------------------------

||| Every name `d`'s own body directly, saturated-ly calls (`RAppName`
||| only) -- see the doc's "Eligibility -- and why it doubles as the
||| profitability gate" for why `RUnderApp`/`RCConstClosure`/`RCon`/
||| `RAppNameRep` references don't matter here.
calleesOf : RCDef -> SortedSet Name
calleesOf = foldRCNamesD ({ onAppName := \n, _ => singleton n } noRCNames)

||| How many `RAppName` calls `d`'s own body makes to each name: its
||| keys are `calleesOf d`, and its counts are what `Carried.counts`
||| sums, so one walk serves both.
callCountsOf : RCDef -> SortedMap Name Nat
callCountsOf d = foldl (\m, n => insert n (S (fromMaybe 0 (lookup n m))) m) empty
                       (foldRCNamesD ({ onAppName := \n, _ => [n] } noRCNames) d)

||| One name's `callCountsOf`, cached across rounds; exact until the name
||| is in `dirty` (see `analyse`).
CalleeInfo : Type
CalleeInfo = SortedMap Name (SortedMap Name Nat)

||| The direct-call graph `info` describes, as `tarjanSCCs` takes it.
callGraph : List (Name, SortedMap Name Nat) -> SortedMap Name (SortedSet Name)
callGraph = SortedMap.fromList . map (\(n, cs) => (n, SortedSet.fromList (keys cs)))

||| Every definition in a direct-call cycle, a self-call included.
cyclicNames : CalleeInfo -> SortedSet Name
cyclicNames info =
    foldl (\acc, scc => case scc of
                            [n] => if maybe False (isJust . lookup n) (lookup n info) then insert n acc else acc
                            _ => foldl (flip insert) acc scc)
          empty (tarjanSCCs (callGraph (SortedMap.toList info)))

record Analysis where
  constructor MkAnalysis
  ||| Callees with exactly one call site that are genuine `MkRCFun`s. A
  ||| cycle does not disqualify one; `callsBack` checks at each splice
  ||| (`rc2/doc/inlining.md`, "Safe despite being part of a larger cycle").
  eligible : SortedSet Name
  ||| Callees before callers where the call graph orders them
  ||| (`tarjanSCCs`), so a chain of single-caller callees collapses in one
  ||| round.
  processOrder : List Name

||| Everything `analyse` carries from one `applyLateInline` round into
||| the next, so a round only pays for whatever actually changed since
||| the last one. `Nothing` on the first round (nothing carried yet).
record Carried where
  constructor MkCarried
  ||| Per-name callee info (see `CalleeInfo`).
  info : CalleeInfo
  ||| Whole-program `RAppName` count per name, updated by delta each round:
  ||| only a `dirty` definition (old occurrences subtracted, new added) or
  ||| a pruned one (old subtracted) can shift it; re-summing every round
  ||| would be the pass's largest cost. The old occurrences come
  ||| from `info`, which still holds the pre-change entry.
  counts : SortedMap Name Nat
  ||| `tarjanSCCs` order, computed on the first round and reused. It only
  ||| decides how many rounds a chain needs, never the result, and `defs`
  ||| only shrinks (`goOrder` skips names no longer in `defOf`).
  order : List Name
  ||| The previous round's own definition names -- what "pruned away
  ||| since last round" is spotted against, for the count delta above.
  names : List Name
  ||| `DeadCode`'s per-name reference sets, so a round does not re-walk
  ||| every body to prune.
  refs : RefCache

||| `prev`: what the last round carried. `dirty`: the names the last round
||| spliced into. Every other body is unchanged (`pruneDeadDefs` only
||| removes names), so its cached `info` entry is exact and only a
||| `dirty` or unseen name is walked again. `defs` only shrinks, so a name
||| present now was cached in the previous round.
analyse : (early : Maybe (SortedSet Name)) -> (seed : CalleeInfo) -> (prev : Maybe Carried) -> (dirty : SortedSet Name) -> (refs : RefCache)
       -> (defOf : SortedMap Name RCDef) -> List (Name, RCDef) -> (Analysis, Carried)
analyse early seed prev dirty refs defOf defs =
    let oldInfo : CalleeInfo = maybe seed (.info) prev
        -- Third component: recomputed this round; only those are written back.
        classified : List (Name, SortedMap Name Nat, Bool) =
                   map (\(n, d) =>
                          case lookup n oldInfo of
                               Just i => if contains n dirty then (n, callCountsOf d, True) else (n, i, False)
                               Nothing => (n, callCountsOf d, True)) defs
        perDef : List (Name, SortedMap Name Nat) = map (\(n, i, _) => (n, i)) classified
        info' : CalleeInfo =
                   foldl (\acc, (n, i, fresh) => if fresh then insert n i acc else acc) oldInfo classified
        -- Fold each definition's list straight into the map: flattening with
        -- `concatMap` is quadratic.
        counts' : SortedMap Name Nat = case prev of
                 Nothing => foldl (\acc, (_, cs) => addAll acc cs) (the (SortedMap Name Nat) empty) perDef
                 Just p => deltaCounts p defOf info'
        -- `reverse (concat sccs)` without building `concat sccs`, same reason.
        order' : List Name = case prev of
                 Nothing => foldl (\acc, scc => foldl (flip (::)) acc scc)
                              [] (tarjanSCCs (callGraph perDef))
                 Just p => p.order
        eligible : SortedSet Name = SortedSet.fromList $ mapMaybe
              (\(n, cnt) => if cnt == 1 && isFun defOf n && not (maybe False (contains n) early) then Just n else Nothing)
              (SortedMap.toList counts')
    in (MkAnalysis eligible order', MkCarried info' counts' order' (map fst defs) refs)
  where
    -- No CAF in the early run: `insertMemoize` hasn't wrapped it yet, so
    -- splicing its body would evaluate it once per run of the caller
    -- (doc/caf-memoization.md, "Limitations").
    isFun : SortedMap Name RCDef -> Name -> Bool
    isFun defOf n = case lookup n defOf of
                         Just (MkRCFun args _ _ _) => isNothing early || not (null args)
                         _ => False

    callsIn : CalleeInfo -> Name -> List (Name, Nat)
    callsIn ci n = maybe [] SortedMap.toList (lookup n ci)

    sub : SortedMap Name Nat -> (Name, Nat) -> SortedMap Name Nat
    sub m (n, k) = case lookup n m of
                        Just c => if c <= k then delete n m else insert n (minus c k) m
                        Nothing => m

    add : SortedMap Name Nat -> (Name, Nat) -> SortedMap Name Nat
    add m (n, k) = insert n (k + fromMaybe 0 (lookup n m)) m

    addAll : SortedMap Name Nat -> SortedMap Name Nat -> SortedMap Name Nat
    addAll m cs = foldl add m (SortedMap.toList cs)

    ||| `prev.counts` adjusted for pruned names and `dirty` ones; the old
    ||| lists come from `prev.info`, the new ones from `newInfo`.
    deltaCounts : Carried -> SortedMap Name RCDef -> CalleeInfo -> SortedMap Name Nat
    deltaCounts p defOf newInfo =
        let gone : List Name = filter (\n => isNothing (lookup n defOf)) p.names
            afterGone : SortedMap Name Nat =
                foldl (\acc, n => foldl sub acc (callsIn p.info n)) p.counts gone
            changed : List Name = filter (\n => isJust (lookup n defOf)) (Prelude.toList dirty)
        in foldl (\acc, n => foldl add (foldl sub acc (callsIn p.info n)) (callsIn newInfo n))
             afterGone changed

||| Whether `callee`'s body directly calls `caller`, checked at each splice
||| decision. One hop is enough, and it only keeps the fixpoint
||| bookkeeping simple, not correctness (`rc2/doc/inlining.md`, "Safe
||| despite being part of a larger cycle").
callsBack : SortedMap Name RCDef -> (caller : Name) -> (callee : Name) -> Bool
callsBack defOf caller callee =
    case lookup callee defOf of
         Just d => contains caller (calleesOf d)
         Nothing => False

------------------------------------------------------------------------
-- Splicing one call site
------------------------------------------------------------------------

||| Every locally-bound id in `e` -- `RLet`'s own `var`, `RConAlt`'s
||| own destructured `args`, `RLoop`'s own `loopParams`. Everything
||| the callee's own body binds *besides* its top-level params, which
||| `spliceCall` renames separately.
export
collectBoundIds : RCExp -> List Int
collectBoundIds (RLet _ var _ value body) = var :: (collectBoundIds value ++ collectBoundIds body)
collectBoundIds (RConCase _ _ alts mDef) =
    concatMap (\(MkRConAlt _ _ _ as body) => as ++ collectBoundIds body) alts ++ maybe [] collectBoundIds mDef
collectBoundIds (RConstCase _ _ alts mDef) =
    concatMap (\(MkRConstAlt _ body) => collectBoundIds body) alts ++ maybe [] collectBoundIds mDef
collectBoundIds (RLoop _ loopParams _ _ body) = map fst loopParams ++ collectBoundIds body
collectBoundIds e = concatMap collectBoundIds (children e)

||| `True` iff `target` occurs in `e` other than as a native-operand read
||| at `ty` or ownership bookkeeping that `Rewrite.stripOwnership` strips
||| (`RDup`/`RDrop`/`RFree`, a node's `postDrop`). `loopSlots`: the
||| nearest enclosing `RLoop`'s params; an `RLoopContinue` entry into a
||| slot already `RNative ty` is safe too, since `Emit` renders it by the
||| slot's `Rep`. See `rc2/doc/inlining.md`, "Criterion B, revisited".
hasNonNativeUse : (ty : PrimType) -> (loopSlots : List (Int, Rep)) -> Int -> RCExp -> Bool
hasNonNativeUse ty loopSlots target (RV _ v) = v == RCLoc target
hasNonNativeUse ty loopSlots target (RAppName _ _ _ args) = elem (RCLoc target) args
hasNonNativeUse ty loopSlots target (RUnderApp _ _ _ args) = elem (RCLoc target) args
hasNonNativeUse ty loopSlots target (RApp _ _ c args) = c == RCLoc target || elem (RCLoc target) args
hasNonNativeUse ty loopSlots target (RLet _ _ _ value body) =
    hasNonNativeUse ty loopSlots target value || hasNonNativeUse ty loopSlots target body
hasNonNativeUse ty loopSlots target (RCon _ _ _ _ args reuseFrom) = elem (RCLoc target) args || reuseFrom == Just (RCLoc target)
hasNonNativeUse ty loopSlots target (ROp {}) = False -- postDrop-only; stale, stripOwnership handles it
hasNonNativeUse ty loopSlots target (RExtPrim _ _ _ args postDrop) = elem (RCLoc target) args || elem (RCLoc target) postDrop
-- Unlike ROp/RCmpCase/..., stripOwnership never touches RExtPrim's own postDrop -- a genuine use here.
hasNonNativeUse ty loopSlots target (RStructGet _ structVar _ _) = structVar == RCLoc target
hasNonNativeUse ty loopSlots target (RDelay _ _ _ caps) = elem (RCLoc target) caps
hasNonNativeUse ty loopSlots target (RForce _ _ v _) = v == RCLoc target
hasNonNativeUse ty loopSlots target (RStructSet _ structVar _ value _) = structVar == RCLoc target || value == RCLoc target
hasNonNativeUse ty loopSlots target (RFill _ cell _ value _) = cell == RCLoc target || value == RCLoc target
hasNonNativeUse ty loopSlots target (RCmpCase _ _ _ _ t f) = hasNonNativeUse ty loopSlots target t || hasNonNativeUse ty loopSlots target f
hasNonNativeUse ty loopSlots target (RConCase _ sc alts mDef) =
    sc == RCLoc target || any (\(MkRConAlt _ _ _ _ body) => hasNonNativeUse ty loopSlots target body) alts
      || maybe False (hasNonNativeUse ty loopSlots target) mDef
-- A native read when the alts match against `ty` (`constAltsNativeType`
-- is shared with `Loop.nativeArgTypes`, so they agree). `RConCase`'s
-- scrutinee above is a constructor and stays a disqualifying use.
hasNonNativeUse ty loopSlots target (RConstCase _ sc alts mDef) =
    (sc == RCLoc target && constAltsNativeType alts /= Just ty)
      || any (\(MkRConstAlt _ body) => hasNonNativeUse ty loopSlots target body) alts
      || maybe False (hasNonNativeUse ty loopSlots target) mDef
hasNonNativeUse ty loopSlots target (RReleaseReuse _ v body) = v == RCLoc target || hasNonNativeUse ty loopSlots target body
-- RReuseOffer's sc/dupOnShared/dropOnUnique are genuine uses, as is RReleaseReuse's v
-- above: stripOwnership deliberately never touches an already-decided reuse.
hasNonNativeUse ty loopSlots target (RReuseOffer _ sc dupOnShared dropOnUnique body) =
    sc == RCLoc target || elem (RCLoc target) dupOnShared || elem (RCLoc target) dropOnUnique
      || hasNonNativeUse ty loopSlots target body
-- The body is checked against THIS loop's slots. `initial` is treated like
-- `RLoopContinue` below: `Emit` renders each entry by the slot's `Rep`, so
-- an `RNative ty` slot is a native read. A Boxed slot, or a length mismatch
-- (`zip` would drop the tail), disqualifies.
hasNonNativeUse ty loopSlots target (RLoop _ loopParams initial _ body) =
    initialNonNative || hasNonNativeUse ty loopParams target body
  where
    -- `nativeSlotTy` is shared with `Loop.nativeArgTypes`, which decides `ty`;
    -- the two must agree on what a native slot is.
    initialNonNative : Bool
    initialNonNative =
        any (\((_, slotRep), a) => a == RCLoc target && nativeSlotTy slotRep /= Just ty)
            (zip loopParams initial)
          || (length initial /= length loopParams && elem (RCLoc target) initial)
hasNonNativeUse ty loopSlots target (RLoopContinue _ args _) =
    any (\((_, slotRep), a) => a == RCLoc target && not (matchesTy slotRep)) (zip loopSlots args)
      || (length args /= length loopSlots && elem (RCLoc target) args)
        -- length mismatch shouldn't happen structurally; falls back to disqualifying rather
        -- than risk `zip` silently dropping a real occurrence in the tail.
  where
    matchesTy : Rep -> Bool
    matchesTy (RNative (TPrim ty')) = ty' == ty
    matchesTy _ = False
-- RPrimVal/RErased/RCrash: no locals, so no children either.
hasNonNativeUse ty loopSlots target e = any (hasNonNativeUse ty loopSlots target) (children e)

||| `Just ty` iff `paramId`'s occurrences in `calleeBody` are all
||| `ty`-typed native-operand reads (`hasNonNativeUse`); `ty` comes from
||| `nativeArgType` first.
loopParamNativeType : (paramId : Int) -> (calleeBody : RCExp) -> Maybe PrimType
loopParamNativeType paramId calleeBody =
    case nativeArgType paramId calleeBody of
         Nothing => Nothing
         Just ty => if hasNonNativeUse ty [] paramId calleeBody then Nothing else Just ty

||| Whether `target` is one of an `RLoop`'s loop-carried slot ids in `e`,
||| i.e. aliasing the caller's local onto it would let the loop reassign
||| that local. See `buildSplice`.
isLoopCarried : Int -> RCExp -> Bool
isLoopCarried target (RLoop _ loopParams _ _ body) = elem target (map fst loopParams) || isLoopCarried target body
isLoopCarried target e = any (isLoopCarried target) (children e)

||| Fresh `buildSplice` ids bound to a constant closure, keyed by id:
||| `RCConstClosure`'s own name and `missing`, which is that callee's
||| *whole* remaining arity (it captures nothing at all, see its doc
||| comment in RCExp.idr).
ConstClosureArgs : Type
ConstClosureArgs = SortedMap Int (Name, Nat)

||| Rewrite a saturated application of one of `ccs`'s ids into a direct
||| call. `ConstFold` does this too, but runs before `buildSplice` mints
||| the `RLet` binding a constant-closure argument, and nothing re-folds it.
|||
||| Safe after `RC.annotate` because the target is a constant closure: its
||| `constclosure_N` static is immortal, so `dup`/`drop` on it are no-ops
||| and an unconsumed reference is unobservable. The `RLet` stays;
||| `DeadVars` removes it when unused.
resolveConstClosureApps : ConstClosureArgs -> RCExp -> RCExp
resolveConstClosureApps ccs e@(RApp fc lazy (RCLoc v) args) =
    case lookup v ccs of
         Nothing => e
         Just (n, missing) =>
             if length args == missing
                then RAppName fc lazy n (forget args)
                else if length args < missing
                        -- Under-application: still a closure, but built
                        -- directly instead of dispatching to build it.
                        -- See `Compiler.RC2.ConstFold`'s own `RApp` case.
                        then RUnderApp fc n (minus missing (length args)) (forget args)
                        else e
-- A loop parameter starts out as its constant closure but every
-- `RLoopContinue` rebinds it, so inside the body it is no longer known.
resolveConstClosureApps ccs (RLoop fc loopParams initial prologueDrop body) =
    RLoop fc loopParams initial prologueDrop
          (resolveConstClosureApps (foldl (\m, (i, _) => delete i m) ccs loopParams) body)
resolveConstClosureApps ccs e = mapChildren (resolveConstClosureApps ccs) e

||| Builds the renaming of the callee's parameter ids onto the call
||| arguments, a wrapper binding each argument that needs its own `RLet`
||| ahead of the renamed body, and the fresh ids bound purely `RNative`
||| (for `stripOwnership` in `spliceCall`).
|||
||| An `RBoxed` caller argument whose param is not loop-carried
||| (`isLoopCarried`) is aliased onto the caller's local. Any other gets a
||| fresh id: aliasing a loop-carried one would let the splice reassign the
||| caller's variable, and a native one needs the `RLet`'s `Rep` as the
||| boxing decision (`RNative ty` only if `loopParamNativeType` agrees at the
||| same type). See `rc2/doc/inlining.md`, "Criterion B, revisited", for
||| why.
buildSplice : {auto v : Ref VarId Int} -> FC -> SortedMap Int Rep -> RCExp -> List (Int, RCLocal) -> Core (Renaming, RCExp -> RCExp, SortedSet Int, ConstClosureArgs)
buildSplice fc reps calleeBody [] = pure (empty, id, empty, empty)
buildSplice fc reps calleeBody ((paramId, actual@(RCLoc actualId)) :: rest) = do
    (ren, wrap, promoted, ccs) <- buildSplice fc reps calleeBody rest
    case argRep reps actual of
         RNative (TPrim ty) => do
             f <- freshVarId
             let (rep, promoted') = case loopParamNativeType paramId calleeBody of
                                          Just ty' => if ty' == ty then (RNative (TPrim ty), SortedSet.insert f promoted) else (RBoxed, promoted)
                                          Nothing => (RBoxed, promoted)
             pure (insert paramId f ren, wrap . RLet fc f rep (RV fc actual), promoted', ccs)
         -- Two params aliased onto one caller local would also share its
         -- `reuseOffer` reservation, letting two cells claim one slot.
         _ => if isLoopCarried paramId calleeBody || elem actual (map snd rest)
                 then do
                     f <- freshVarId
                     pure (insert paramId f ren, wrap . RLet fc f RBoxed (RV fc actual), promoted, ccs)
                 else pure (insert paramId actualId ren, wrap, promoted, ccs)
  where
    argRep : SortedMap Int Rep -> RCLocal -> Rep
    argRep reps (RCLoc j) = case lookup j reps of
                                 Just (RInlineNative (TPrim ty)) => RNative (TPrim ty)
                                 Just r => r
                                 Nothing => RBoxed
    argRep _ _ = RBoxed
-- `actual` is a constant (`RCEmptyCon`/`RCConstCon`/`RCConstClosure` or a
-- literal folded by `ConstFold`): no caller local to alias, so it always
-- gets a fresh declaration. A native-eligible literal (`litRep`) whose
-- reads are all native at that type is bound `RNative`; the rest stay
-- `RBoxed`.
buildSplice fc reps calleeBody ((paramId, actual) :: rest) = do
    (ren, wrap, promoted, ccs) <- buildSplice fc reps calleeBody rest
    f <- freshVarId
    let (rep, promoted') = case constLitRep actual of
                                Nothing => (RBoxed, promoted)
                                Just ty => case loopParamNativeType paramId calleeBody of
                                                Just ty' => if ty' == ty
                                                               then (RNative (TPrim ty), SortedSet.insert f promoted)
                                                               else (RBoxed, promoted)
                                                Nothing => (RBoxed, promoted)
    -- A constant *closure* argument is recorded for
    -- `resolveConstClosureApps`: the callee's own body going on to
    -- apply this parameter is a statically-known call, and nothing
    -- re-folds it after this pass.
    let ccs' = case actual of
                    RCConstClosure n missing => insert f (n, missing) ccs
                    _ => ccs
    pure (insert paramId f ren, wrap . RLet fc f rep (RV fc actual), promoted', ccs')
  where
    constLitRep : RCLocal -> Maybe PrimType
    constLitRep (RCConst c) = litRep c
    constLitRep _ = Nothing

||| Every id from `collectBoundIds`, freshened. Needed although `VarId`s
||| are globally unique: `SpecClosure` clones share internal ids, and
||| splicing two clones into one caller would redefine them
||| (`rc2/doc/inlining.md`, "Criterion B, revisited", `var_301`).
export
freshenBoundIds : {auto v : Ref VarId Int} -> List Int -> Core Renaming
freshenBoundIds [] = pure empty
freshenBoundIds (i :: is) = do
    ren <- freshenBoundIds is
    f <- freshVarId
    pure (insert i f ren)

||| Whether `Emit.emitNativeValue` can render `e` as one C expression:
||| `RAppFFIInline`/`ROp`/`RPrimVal` at the tail under
||| `RLet`/`RDup`/`RFree`/`RDrop`/`RReleaseReuse`, no branch and no
||| `RLoop`. `uniformTailType` alone says yes through a branch, which
||| crashed (`rc2/doc/inlining.md`, "Criterion B, revisited").
emitNativeValueCompatible : RCExp -> Bool
emitNativeValueCompatible (RAppFFIInline {}) = True
emitNativeValueCompatible (ROp {}) = True
emitNativeValueCompatible (RPrimVal _ _) = True
emitNativeValueCompatible (RLet _ _ _ _ body) = emitNativeValueCompatible body
emitNativeValueCompatible (RDup _ _ _ cont) = emitNativeValueCompatible cont
emitNativeValueCompatible (RFree _ _ cont) = emitNativeValueCompatible cont
emitNativeValueCompatible (RDrop _ _ cont) = emitNativeValueCompatible cont
emitNativeValueCompatible (RReleaseReuse _ _ cont) = emitNativeValueCompatible cont
emitNativeValueCompatible _ = False

||| `Just ty` iff every tail exit of `e` has the same native type
||| (`DualABI.tailValueReps`). `promotableNativeLetRep` uses it to decide whether the
||| `RLet` of a spliced call can become native.
uniformTailType : RCExp -> Maybe PrimType
uniformTailType e = case tailValueReps empty e of
                          (Just ty :: rest) => if all (== Just ty) rest then Just ty else Nothing
                          _ => Nothing

||| `Just ty` iff an `RBoxed` `RLet var value body` can become native
||| `ty`: `value`'s tail is uniformly native, `Emit` can render it as one
||| expression, and `body` uses `var` only natively. `loopSlots` goes to
||| `hasNonNativeUse`. See `rc2/doc/inlining.md`, "Criterion B, revisited",
||| Layers 2/3.
export
promotableNativeLetRep : (loopSlots : List (Int, Rep)) -> (var : Int) -> (value : RCExp) -> (body : RCExp) -> Maybe PrimType
promotableNativeLetRep loopSlots var value body =
    case uniformTailType value of
         Just ty => if emitNativeValueCompatible value && not (hasNonNativeUse ty loopSlots var body) then Just ty else Nothing
         Nothing => Nothing

||| Replace one fully-saturated call to an eligible callee with its own
||| (renamed) body. `reps`: the caller's own current `Rep` environment
||| at this exact call site (`inlineInto`'s own walk), consulted by
||| `buildSplice` above -- never the callee's own declared param `Rep`.
spliceCall : {auto v : Ref VarId Int} -> FC -> SortedMap Int Rep -> RCDef -> List RCLocal -> Core RCExp
spliceCall fc reps (MkRCFun calleeArgs _ _ calleeBody) actualArgs = do
    (paramRen, wrap, promoted, ccs) <- buildSplice fc reps calleeBody (zip (map fst calleeArgs) actualArgs)
    let paramIds = SortedSet.fromList (map fst calleeArgs)
    internalRen <- freshenBoundIds (filter (\i => not (contains i paramIds)) (collectBoundIds calleeBody))
    let ren = foldl (\acc, (k, val) => insert k val acc) paramRen (SortedMap.toList internalRen)
    -- `promoted` ids are purely `RNative` (a value type is not refcounted, so
    -- nothing to reannotate), unlike `ConAltNative`'s shadows.
    pure $ wrap (resolveConstClosureApps ccs (stripOwnership promoted (renameRCExp ren calleeBody)))
-- Defensive only -- `eligible` (built from `isFun` in `analyse`) never
-- names anything but a `MkRCFun`.
spliceCall _ _ d _ = pure $ RCrash EmptyFC "[rc2] internal: LateInline target wasn't a MkRCFun"

------------------------------------------------------------------------
-- Whole-tree rewrite: replace every eligible call site
------------------------------------------------------------------------

||| Rewrites every call to an `eligible` callee in the body of `self` into
||| its spliced body, walking every wrapper node `annotate` and `Loop` can
||| have produced. `reps` (each local's declared `Rep`, extended at
||| `RLet`/`RLoop`) is what `buildSplice` binds arguments by, not the
||| callee's declared param `Rep`. A callee that calls `self` back is
||| refused (`callsBack`).
inlineInto : {auto v : Ref VarId Int} -> SortedMap Name RCDef -> SortedSet Name -> (self : Name) -> RCExp -> Core RCExp
inlineInto defOf eligible self = go empty []
  where
    -- `loopSlots`: the nearest enclosing `RLoop`'s params (`[]` outside a
    -- loop), kept apart from `reps` because it must reflect the loop already
    -- walked through ("Criterion B, revisited", Layer 3).
    go : SortedMap Int Rep -> List (Int, Rep) -> RCExp -> Core RCExp
    go reps loopSlots (RAppName fc lazy n args) =
        if contains n eligible && not (callsBack defOf self n)
           then case lookup n defOf of
                     Just d => spliceCall fc reps d args
                     Nothing => pure (RAppName fc lazy n args)
           else pure (RAppName fc lazy n args)
    -- The call is an `RLet`'s still-`RBoxed` value: `promotableNativeLetRep`
    -- decides whether `var` can become native (the return-side twin of
    -- `buildSplice`'s argument promotion).
    go reps loopSlots (RLet fc var RBoxed value@(RAppName vfc lazy n args) body) =
        if contains n eligible && not (callsBack defOf self n)
           then case lookup n defOf of
                     Just d => do
                         splicedValue <- spliceCall vfc reps d args
                         case promotableNativeLetRep loopSlots var splicedValue body of
                              Just ty => do
                                  body' <- go (insert var (RNative (TPrim ty)) reps) loopSlots body
                                  pure $ RLet fc var (RNative (TPrim ty)) splicedValue (stripOwnership (SortedSet.singleton var) body')
                              Nothing => RLet fc var RBoxed splicedValue <$> go reps loopSlots body
                     Nothing => RLet fc var RBoxed value <$> go reps loopSlots body
           else RLet fc var RBoxed value <$> go reps loopSlots body
    go reps loopSlots (RLet fc var rep value body) = RLet fc var rep <$> go reps loopSlots value <*> go (insert var rep reps) loopSlots body
    go reps loopSlots (RLoop fc loopParams initial prologueDrop body) =
        RLoop fc loopParams initial prologueDrop <$> go (foldl (\m, (i, r) => insert i r m) reps loopParams) loopParams body
    go reps loopSlots e = traverseChildren @{Applicative.CORE} (go reps loopSlots) e

------------------------------------------------------------------------
-- Whole-program entry point
------------------------------------------------------------------------

||| One round: prune what is unreachable from `roots`, then splice every
||| single-caller callee into its call site, callees before callers (see
||| rc2/doc/inlining.md, "Eligibility -- and why it doubles as the
||| profitability gate" and "Iterated to a fixpoint"). The `Bool` is `False`
||| when nothing was spliced; pruning alone doesn't count, since the next
||| round would see the same program. `prev`/`dirty`: see `analyse`.
|||
||| The `logTime`s wrap `pure $ <computation>`, not a `let`: a `let` runs
||| before the timer starts and reports nothing.
applyLateInlineOnce : {auto v : Ref VarId Int} -> {auto c : Ref Ctxt Defs} -> (early : Maybe (SortedSet Name)) -> (seed : CalleeInfo) -> (roots : List Name) -> Maybe Carried -> SortedSet Name -> List (Name, RCDef) -> Core (Bool, List (Name, RCDef), Carried, SortedSet Name)
applyLateInlineOnce early seed roots prev dirty defs0 = do
    (defs, refs') <- logTime 3 "rc2: LI prune" $
              pure $ pruneDeadDefsCached (maybe empty (.refs) prev) dirty roots defs0
    -- Shared with `goOrder`: `analyse` and the splice walk both need it.
    defOf <- logTime 3 "rc2: LI defOf" $ pure $ SortedMap.fromList defs
    (an, carried) <- logTime 3 "rc2: LI analyse" $ pure $ analyse early seed prev dirty refs' defOf defs
    case leftMost an.eligible of
         Nothing => pure (False, defs, carried, empty)
         Just _ => do
             -- Only names with a callee `inlineInto` would actually splice (`eligible`
             -- and not calling back, nearly the test of its `RAppName` cases) are walked.
             -- `carried.info` already holds each callee set, so this is a lookup per
             -- callee; `callsBack` would re-walk the callee's body. The weaker "has an
             -- eligible callee" test keeps reporting a change and the loop never stops.
             let callsBackCached : Name -> Name -> Bool
                 callsBackCached caller callee =
                     case lookup callee carried.info of
                          Just cs => isJust (lookup caller cs)
                          Nothing => False
             -- The `defOf` test is needed: `carried.info` and `processOrder` still name
             -- definitions already pruned, and such a name would re-qualify every
             -- round, so the loop would never converge.
             let splicesInto : Name -> Bool
                 splicesInto n =
                     isJust (lookup n defOf) &&
                     (case lookup n carried.info of
                           Just cs => any (\c => contains c an.eligible && not (callsBackCached n c))
                                          (keys cs)
                           Nothing => False)
             let toProcess = filter splicesInto an.processOrder
             final <- goOrder an.eligible toProcess defOf
             pure (not (isNil toProcess),
                   map (\(n, d) => (n, fromMaybe d (lookup n final))) defs, carried, SortedSet.fromList toProcess)
  where
    goOrder : SortedSet Name -> List Name -> SortedMap Name RCDef -> Core (SortedMap Name RCDef)
    goOrder eligible [] defOf = pure defOf
    goOrder eligible (n :: rest) defOf = do
        defOf' <- case lookup n defOf of
                       Just (MkRCFun args retRep isWorker body) => do
                           body' <- inlineInto defOf eligible n body
                           pure (insert n (MkRCFun args retRep isWorker body') defOf)
                       Just (MkRCError body) => do
                           body' <- inlineInto defOf eligible n body
                           pure (insert n (MkRCError body') defOf)
                       _ => pure defOf
        goOrder eligible rest defOf'

||| Iteration cap for `applyLateInline`. Only a guard: the loop stops by
||| itself once a round splices nothing.
maxLateInlineIterations : Nat
maxLateInlineIterations = 8

||| Runs `applyLateInlineOnce` until a round splices nothing or
||| `maxLateInlineIterations` is reached, threading `Carried` and the
||| previous round's `toProcess` (as `dirty`) from round to round. `roots`
||| are the entry points `pruneDeadDefs` is called with. Each round is
||| `logTime`d at `--timing 3`, labelled with how many definitions the
||| previous round spliced into, which tells a converging tail from real
||| work.
export
applyLateInline : {auto v : Ref VarId Int} -> {auto c : Ref Ctxt Defs} -> (label : String) -> (early : Bool)
               -> (roots : List Name) -> List (Name, RCDef) -> Core (List (Name, RCDef))
applyLateInline label early roots defs0 =
    -- The early run skips every callee in a call cycle: splicing one would
    -- turn the cycle into a direct call back to the caller, which the later
    -- run then refuses (constructor-escape-analysis.md, "Early inline").
    -- Bound here, not in `where`, so it is computed once
    -- (constant-constructor-specialization.md, "The `where`-clause trap").
    do seed <- logTime 3 "rc2: \{label} (call counts)" $ pure $ SortedMap.fromList (map (\(n, d) => (n, callCountsOf d)) defs0)
       excluded <- if early then logTime 3 "rc2: \{label} (call cycles)" $ pure $ Just (cyclicNames seed) else pure Nothing
       go seed excluded 1 maxLateInlineIterations Nothing empty defs0
  where
    go : CalleeInfo -> Maybe (SortedSet Name) -> Nat -> Nat -> Maybe Carried -> SortedSet Name -> List (Name, RCDef) -> Core (List (Name, RCDef))
    go _ _ round Z prev dirty defs = pure defs
    go seed excluded round (S fuel) prev dirty defs = do
        let carriedNote = if round == 1
                             then "first pass"
                             else "\{show (length (Prelude.toList dirty))} spliced last round"
        (changed, defs', carried, dirty') <-
            logTime 3 "rc2: \{label} (round \{show round}/\{show maxLateInlineIterations}, \{carriedNote})" $
              applyLateInlineOnce excluded seed roots prev dirty defs
        if changed then go seed excluded (S round) fuel (Just carried) dirty' defs' else pure defs'
