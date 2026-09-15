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

import Compiler.RC2.DualABI
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

||| `True` iff `target` occurs *anywhere* in `e` outside of an
||| `ROp`/`RCmpCase`'s own operand list -- a bare read, a call/
||| constructor/extprim argument, a struct field, a loop's own
||| `initial`/`prologueDrop`/`RLoopContinue`'s own `args`, or anywhere
||| else. Paired with `Compiler.RC2.Loop`'s own `nativeArgType` (which
||| only asks "if read this way, do they all agree on one type" -- not
||| "is this *every* way it's read"), a substituted parameter with
||| `False` here and a `Just ty` there has *every* one of its own
||| occurrences accounted for by a correctly-typed native-operand read
||| -- nothing left that could ever need a genuine Boxed
||| representation, hence nothing left needing ownership bookkeeping
||| either (a value type is never refcounted).
|||
||| `ty`: the native type `target` is a candidate to be declared at --
||| needed for the one case that isn't purely structural,
||| `RLoopContinue`'s own `args`: a `target` entry there is safe (not a
||| genuine non-native use) exactly when the *nearest enclosing*
||| `RLoop`'s own loop-carried slot at that same position is *already*
||| declared `RNative ty` too -- `Emit.idr`'s own `tryEmitLoopContinue`
||| always renders a continue's own new value through
||| `rcVarToNativeC`/`rcVarToBoxedC` keyed on *that slot's* own `Rep`,
||| never the supplied value's, so this is exactly the check needed
||| (and, since the slot's declared type is fixed independently of
||| `target`, this is also why `ty` must already be settled before this
||| function can answer -- unlike `Compiler.RC2.Loop`'s own
||| `nativeArgType`, which discovers a consistent type as it goes).
||| `loopSlots`: the nearest enclosing `RLoop`'s own `loopParams`,
||| threaded here for exactly that check -- `[]` until this function's
||| own `RLoop` case descends into one.
|||
||| Deliberately conservative about `RLoop`'s own `initial`/
||| `prologueDrop` regardless (native-compatible in principle if the
||| loop-carried slot itself is native too, but not verified here) --
||| narrower than theoretically possible, never wrong.
hasNonNativeUse : (ty : PrimType) -> (loopSlots : List (Int, Rep)) -> Int -> RCExp -> Bool
hasNonNativeUse ty loopSlots target (RV _ v) = v == RCLoc target
hasNonNativeUse ty loopSlots target (RAppName _ _ _ args) = elem (RCLoc target) args
hasNonNativeUse ty loopSlots target (RUnderApp _ _ _ args) = elem (RCLoc target) args
hasNonNativeUse ty loopSlots target (RApp _ _ c a) = c == RCLoc target || a == RCLoc target
hasNonNativeUse ty loopSlots target (RLet _ _ _ value body) =
    hasNonNativeUse ty loopSlots target value || hasNonNativeUse ty loopSlots target body
hasNonNativeUse ty loopSlots target (RCon _ _ _ _ args reuseFrom) = elem (RCLoc target) args || reuseFrom == Just (RCLoc target)
-- `args` themselves are the native-operand position `nativeArgType`
-- already verifies. `postDrop` here is ordinary ownership bookkeeping
-- (a Boxed-drop `annotate` attached, assuming `target` still needed
-- boxing) -- `Compiler.RC2.Loop`'s own `stripOwnership` (reused by
-- `spliceCall` below) already filters exactly this list, so a
-- `target` entry here is stale, not a genuine non-native use.
hasNonNativeUse ty loopSlots target (ROp {}) = False
hasNonNativeUse ty loopSlots target (RExtPrim _ _ _ args postDrop) = elem (RCLoc target) args || elem (RCLoc target) postDrop
-- `stripOwnership` doesn't touch `RExtPrim`'s own `postDrop` at all
-- (unlike `ROp`/`RCmpCase`/... below) -- kept as a genuine non-native
-- use here to match, not because it can't in principle be native.
hasNonNativeUse ty loopSlots target (RStructGet _ structVar _ _ _) = structVar == RCLoc target
-- `postDrop` here is stripped by `stripOwnership` too, same as `ROp`.
hasNonNativeUse ty loopSlots target (RStructSet _ structVar _ _ value _) = structVar == RCLoc target || value == RCLoc target
hasNonNativeUse ty loopSlots target (RCmpCase _ _ _ _ t f) = hasNonNativeUse ty loopSlots target t || hasNonNativeUse ty loopSlots target f
-- Same reasoning as `ROp` above -- `postDrop` here is stripped too.
hasNonNativeUse ty loopSlots target (RConCase _ sc alts mDef) =
    sc == RCLoc target || any (\(MkRConAlt _ _ _ _ body) => hasNonNativeUse ty loopSlots target body) alts
      || maybe False (hasNonNativeUse ty loopSlots target) mDef
hasNonNativeUse ty loopSlots target (RConstCase _ sc alts mDef) =
    sc == RCLoc target || any (\(MkRConstAlt _ body) => hasNonNativeUse ty loopSlots target body) alts
      || maybe False (hasNonNativeUse ty loopSlots target) mDef
-- `RDup`/`RDrop`/`RFree`'s own target mention is itself ownership
-- bookkeeping `stripOwnership` removes outright (the whole node, for
-- `RDup`/`RFree`; just this one entry, for `RDrop`'s own list) -- a
-- `target` match here is stale too, same reasoning as `ROp`'s own
-- `postDrop` above, not a genuine non-native use.
hasNonNativeUse ty loopSlots target (RDup _ v _ body) = hasNonNativeUse ty loopSlots target body
hasNonNativeUse ty loopSlots target (RDrop _ vars body) = hasNonNativeUse ty loopSlots target body
hasNonNativeUse ty loopSlots target (RFree _ v body) = hasNonNativeUse ty loopSlots target body
-- `RReleaseReuse`'s own `v` and `RReuseOffer`'s own `sc`/
-- `dupOnShared`/`dropOnUnique` are genuine structural uses (a reused
-- constructor's own storage slot) `stripOwnership` deliberately never
-- touches (see its own doc comment: never disturbing an
-- already-decided reuse) -- a value type would never appear here in
-- practice, but kept as a real non-native use for safety regardless.
hasNonNativeUse ty loopSlots target (RReleaseReuse _ v body) = v == RCLoc target || hasNonNativeUse ty loopSlots target body
hasNonNativeUse ty loopSlots target (RReuseOffer _ sc dupOnShared dropOnUnique body) =
    sc == RCLoc target || elem (RCLoc target) dupOnShared || elem (RCLoc target) dropOnUnique
      || hasNonNativeUse ty loopSlots target body
-- `loopParams`'s own ids are binding positions (what a loop-carried
-- slot is *called*), never a use of `target` -- but `body` is now
-- checked against *this* loop's own slots (`RLoopContinue`'s own case
-- below), not whatever enclosing one `loopSlots` still held.
-- `prologueDrop` is ownership bookkeeping `stripOwnership` filters
-- too, same reasoning as `ROp`'s own `postDrop` above. `initial` is a
-- genuine use, conservatively treated as non-native (see this
-- function's own doc comment).
hasNonNativeUse ty loopSlots target (RLoop _ loopParams initial _ body) =
    elem (RCLoc target) initial || hasNonNativeUse ty loopParams target body
-- `postDrop` here is stripped too. `args`: safe (not a genuine
-- non-native use) exactly at the positions whose own same-index
-- `loopSlots` entry is already `RNative ty` -- see this function's
-- own doc comment.
hasNonNativeUse ty loopSlots target (RLoopContinue _ args _) =
    any (\((_, slotRep), a) => a == RCLoc target && not (matchesTy slotRep)) (zip loopSlots args)
      || length args /= length loopSlots
        -- Structurally shouldn't happen (`RLoopContinue`'s own arg
        -- list is always the same length as its loop's own
        -- `loopParams`) -- if it somehow does, `zip` would silently
        -- drop the extra entries above, so this defensively falls
        -- back to disqualifying instead of missing a real `target`
        -- occurrence in the dropped tail.
        && elem (RCLoc target) args
  where
    matchesTy : Rep -> Bool
    matchesTy (RNative ty') = ty' == ty
    matchesTy _ = False
hasNonNativeUse ty loopSlots target (RMemoize _ _ _ body) = hasNonNativeUse ty loopSlots target body
-- RPrimVal, RErased, RCrash: no locals at all. RAppNameRep/
-- RAppFFIInline can't exist yet -- Compiler.RC2.DualABI runs strictly
-- after this pass (matches `inlineInto`'s own reasoning below).
hasNonNativeUse _ _ _ _ = False

||| `Just ty` iff `paramId`'s own occurrences in `calleeBody` are
||| *entirely* accounted for by consistently-`ty`-typed native-operand
||| reads -- see `hasNonNativeUse`'s own doc comment for the two-part
||| check this combines. `ty` itself has to come from `nativeArgType`
||| first (`hasNonNativeUse` needs it already settled, see its own doc
||| comment), so unlike that simpler boolean check alone, this one
||| can't run in the other order.
nativeEligible : (paramId : Int) -> (calleeBody : RCExp) -> Maybe PrimType
nativeEligible paramId calleeBody =
    case nativeArgType paramId calleeBody of
         Nothing => Nothing
         Just ty => if hasNonNativeUse ty [] paramId calleeBody then Nothing else Just ty

||| Builds the renaming from `calleeArgs`'s own top-level param ids
||| onto the actual call arguments, plus a wrapping function for any
||| argument, bound via one `RLet` ahead of the callee's own renamed
||| body, plus every fresh id bound purely `RNative` this way (for
||| `spliceCall`'s own final `stripOwnership` pass).
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
|||
||| The fresh id's own `Rep`: `RBoxed` (matching the callee's own
||| original param declaration, always `RBoxed` this early in the
||| pipeline) *unless* the actual argument is currently native in the
||| caller (`reps`) *and* `nativeEligible` confirms the callee's own
||| body never needs it any other way, at the very same type. Getting
||| this backwards -- declaring native without confirming eligibility,
||| or declaring native while leaving the callee's own stale
||| Boxed-assuming `RDup`/`RDrop` nodes in place -- was a real,
||| `valgrind`-clean-but-C-compile-error-producing bug found while
||| implementing this (`idris2rc2_drop` handed a raw `int64_t`); always
||| defaulting to `RBoxed` instead was a real, found *performance* bug
||| (`rc2/tests/BenchChain.idr` regressed from 0.008s to 0.39s, a ~50x
||| slowdown, once its own `poly` helper -- purely arithmetic, single-
||| caller-eligible -- got spliced in with every native loop
||| accumulator boxed on the way in and unboxed straight back out on
||| the very next operand read). See `rc2/doc/inlining.md`'s own
||| "Criterion B, revisited" section for the full writeup of both.
buildSplice : {auto v : Ref VarId Int} -> FC -> SortedMap Int Rep -> RCExp -> List (Int, RCLocal) -> Core (Renaming, RCExp -> RCExp, SortedSet Int)
buildSplice fc reps calleeBody [] = pure (empty, id, empty)
buildSplice fc reps calleeBody ((paramId, actual) :: rest) = do
    (ren, wrap, promoted) <- buildSplice fc reps calleeBody rest
    f <- freshVarId
    let (rep, promoted') = case argRep reps actual of
                                 RNative ty => case nativeEligible paramId calleeBody of
                                                    Just ty' => if ty' == ty then (RNative ty, SortedSet.insert f promoted) else (RBoxed, promoted)
                                                    Nothing => (RBoxed, promoted)
                                 _ => (RBoxed, promoted)
    pure (insert paramId f ren, wrap . RLet fc f rep (RV fc actual), promoted')
  where
    argRep : SortedMap Int Rep -> RCLocal -> Rep
    argRep reps (RCLoc j) = case lookup j reps of
                                 Just (RInlineNative ty) => RNative ty
                                 Just r => r
                                 Nothing => RBoxed
    argRep _ _ = RBoxed

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

||| Whether `Compiler.RC2.Emit`'s own `emitNativeValue` (the single
||| inline-C-expression renderer `declareNative`/`inlineNative` use for
||| an `RNative`/`RInlineNative` local's own value) can actually render
||| `e`. Unlike a full statement-level lowering, `emitNativeValue` has
||| no way to represent a branch (`RConCase`/`RConstCase`/`RCmpCase`)
||| or a nested `RLoop` as a single C expression -- it only understands
||| `RAppFFIInline`/`ROp`/`RPrimVal` at the tail, unwinding
||| `RLet`/`RDup`/`RFree`/`RDrop`/`RReleaseReuse` wrappers on the way
||| (mirrored here exactly, constructor-for-constructor). `RAppFFIInline`
||| can't actually occur in a tree this pass ever sees (`Compiler.RC2.
||| DualABI` produces it, and runs strictly after this pass -- see the
||| module doc's "Pipeline position"); included anyway so this stays a
||| honest mirror of what `emitNativeValue` supports, not a guess.
|||
||| Needed because `uniformTailType` below only asks "does every tail
||| position agree on one native type", which is true even when those
||| tail positions sit behind a case-split `emitNativeValue` has no way
||| to lower -- found via a real regression: promoting a spliced call's
||| result to `RNative ty` on `uniformTailType` alone crashed
||| `declareNative` with "[rc2] internal: expected a native-producing
||| expression" the moment the callee's own body branched (e.g. an
||| `if`/`RCmpCase` compiled by `Compiler.RC2.RC`'s own `tryFuseCompare`)
||| before reaching its native tail.
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

||| `Just ty` iff every tail-position exit of `e` agrees on the same
||| native type `ty` (`Compiler.RC2.DualABI`'s own `tailValueReps`,
||| reused as-is -- already correctly seeded purely from `e`'s own
||| `RLet`/`RLoop` bindings as it walks them, `empty` needs nothing
||| pre-populated). Consulted by `inlineInto`'s own `RLet`-with-
||| directly-called-value case to decide whether *that* `RLet`'s own
||| declaration can also become native -- see `spliceCall`'s own doc
||| comment for why this is a separate, later-added concern from
||| `buildSplice`'s own argument-side one.
uniformTailType : RCExp -> Maybe PrimType
uniformTailType e = case tailValueReps empty e of
                          (Just ty :: rest) => if all (== Just ty) rest then Just ty else Nothing
                          _ => Nothing

||| Replace one fully-saturated call to an eligible callee with its own
||| (renamed) body, plus whether that whole result's own tail value is
||| uniformly native (`uniformTailType`, for `inlineInto`'s own
||| `RLet`-with-directly-called-value case to use). `reps`: the
||| caller's own current `Rep` environment at this exact call site
||| (`inlineInto`'s own walk), consulted by `buildSplice` above --
||| never the callee's own originally-declared param `Rep`.
spliceCall : {auto v : Ref VarId Int} -> FC -> SortedMap Int Rep -> RCDef -> List RCLocal -> Core (RCExp, Maybe PrimType)
spliceCall fc reps (MkRCFun calleeArgs _ _ calleeBody) actualArgs = do
    (paramRen, wrap, promoted) <- buildSplice fc reps calleeBody (zipArgs (map fst calleeArgs) actualArgs)
    let paramIds = SortedSet.fromList (map fst calleeArgs)
    internalRen <- freshenBoundIds (filter (\i => not (contains i paramIds)) (collectBoundIds calleeBody))
    let ren = foldl (\acc, (k, val) => insert k val acc) paramRen (SortedMap.toList internalRen)
    -- `promoted` names post-rename (fresh) ids declared purely
    -- `RNative` above -- their own inherited Boxed-assuming ownership
    -- nodes (`Compiler.RC2.Loop`'s own `stripOwnership`, already
    -- `RLoop`-aware) are stale now: a value type is never refcounted,
    -- so there is nothing left to reannotate afterward either, unlike
    -- `Compiler.RC2.ConAltNative`'s own fuller native-shadow promotion
    -- (a field there can still have a *surviving* Boxed-context use;
    -- `nativeEligible` above already ruled that out here).
    let result = wrap (stripOwnership promoted (renameRCExp ren calleeBody))
    pure (result, uniformTailType result)
  where
    zipArgs : List Int -> List RCLocal -> List (Int, RCLocal)
    zipArgs (i :: is) (a :: as) = (i, a) :: zipArgs is as
    zipArgs _ _ = []
-- Defensive only -- `eligible` (built from `isFun` in `analyse`) never
-- names anything but a `MkRCFun`.
spliceCall _ _ d _ = pure (RCrash EmptyFC "[rc2] internal: LateInline target wasn't a MkRCFun", Nothing)

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
|||
||| Threads `reps` (every `RCLoc`'s own currently-declared `Rep`,
||| extended at each `RLet`/`RLoop` binding walked through) down to
||| `spliceCall`'s own `buildSplice` -- see that function's own doc
||| comment for why this, not the callee's own declared param `Rep`,
||| decides how a spliced-in argument gets bound.
inlineInto : {auto v : Ref VarId Int} -> SortedMap Name RCDef -> SortedSet Name -> RCExp -> Core RCExp
inlineInto defOf eligible = go empty []
  where
   mutual
    -- `where` clauses aren't implicitly `mutual` in this Idris2 version
    -- -- `go`'s own RConCase/RConstCase cases below need `goMaybe`
    -- (defined after `go` here for readability), so this block needs
    -- to be explicit about it (confirmed empirically: dropping this
    -- reproduces "Undefined name ... goMaybe" even with `goMaybe`
    -- placed textually after every use).
    --
    -- `loopSlots` mirrors `reps` but tracks only the *nearest
    -- enclosing* `RLoop`'s own `loopParams` (`[]` outside of any
    -- loop) -- needed so `hasNonNativeUse`'s own `RLoopContinue` case
    -- can be asked "is this id read back at a position whose declared
    -- slot type already matches?" even when the `RLoopContinue` in
    -- question isn't textually nested under a *further* `RLoop` inside
    -- the very `RCExp` being scanned (the common case: a call's result
    -- feeds an `RLoop` this same `go` recursion already descended
    -- through *before* reaching the `RLet` that binds it). Passing a
    -- hardcoded `[]` here instead reproduces a real, measured
    -- performance bug -- see `rc2/doc/inlining.md`.
    go : SortedMap Int Rep -> List (Int, Rep) -> RCExp -> Core RCExp
    go reps loopSlots (RAppName fc lazy n args) =
        if contains n eligible
           then case lookup n defOf of
                     Just d => fst <$> spliceCall fc reps d args
                     Nothing => pure (RAppName fc lazy n args)
           else pure (RAppName fc lazy n args)
    -- The call sits directly as an `RLet`'s own value, still `RBoxed`
    -- (the common shape an ordinary, not-yet-`Compiler.RC2.DualABI`-
    -- touched call site always has) -- if the whole splice's own tail
    -- value turns out uniformly native (`spliceCall`'s own second
    -- result), promote `var`'s own declaration to match, *and* strip
    -- its own now-stale Boxed-assuming ownership bookkeeping from
    -- `body` too (`Compiler.RC2.Loop`'s own `stripOwnership`) -- but
    -- only when `body` itself never needs `var` any other way
    -- (`hasNonNativeUse`, the same check `nativeEligible` above uses
    -- for a callee's own parameter, here asked about the caller's own
    -- downstream code instead). Found via a real, found *performance*
    -- bug, the return-side twin of `buildSplice`'s own argument-side
    -- one: leaving `var` declared `RBoxed` here boxes a provably-
    -- native result on the way in, immediately unboxed back out at
    -- its very next (native-operand) read -- see `rc2/doc/inlining.md`
    -- for the measured cost.
    go reps loopSlots (RLet fc var RBoxed value@(RAppName vfc lazy n args) body) =
        if contains n eligible
           then case lookup n defOf of
                     Just d => do
                         (splicedValue, mty) <- spliceCall vfc reps d args
                         case mty of
                              Just ty =>
                                  if not (emitNativeValueCompatible splicedValue) || hasNonNativeUse ty loopSlots var body
                                     then RLet fc var RBoxed splicedValue <$> go reps loopSlots body
                                     else do
                                         body' <- go (insert var (RNative ty) reps) loopSlots body
                                         pure $ RLet fc var (RNative ty) splicedValue (stripOwnership (SortedSet.singleton var) body')
                              Nothing => RLet fc var RBoxed splicedValue <$> go reps loopSlots body
                     Nothing => RLet fc var RBoxed value <$> go reps loopSlots body
           else RLet fc var RBoxed value <$> go reps loopSlots body
    go reps loopSlots (RLet fc var rep value body) = RLet fc var rep <$> go reps loopSlots value <*> go (insert var rep reps) loopSlots body
    go reps loopSlots (RCmpCase fc op args postDrop t f) = RCmpCase fc op args postDrop <$> go reps loopSlots t <*> go reps loopSlots f
    go reps loopSlots (RConCase fc sc alts mDef) = RConCase fc sc <$> traverse goAlt alts <*> goMaybe reps loopSlots mDef
      where
        goAlt : RConAlt -> Core RConAlt
        goAlt (MkRConAlt n ci tag as body) = MkRConAlt n ci tag as <$> go reps loopSlots body
    go reps loopSlots (RConstCase fc sc alts mDef) = RConstCase fc sc <$> traverse goConstAlt alts <*> goMaybe reps loopSlots mDef
      where
        goConstAlt : RConstAlt -> Core RConstAlt
        goConstAlt (MkRConstAlt c body) = MkRConstAlt c <$> go reps loopSlots body
    go reps loopSlots (RLoop fc loopParams initial prologueDrop body) =
        RLoop fc loopParams initial prologueDrop <$> go (foldl (\m, (i, r) => insert i r m) reps loopParams) loopParams body
    go reps loopSlots (RDup fc v extra body) = RDup fc v extra <$> go reps loopSlots body
    go reps loopSlots (RDrop fc vs body) = RDrop fc vs <$> go reps loopSlots body
    go reps loopSlots (RFree fc v body) = RFree fc v <$> go reps loopSlots body
    go reps loopSlots (RReleaseReuse fc v body) = RReleaseReuse fc v <$> go reps loopSlots body
    go reps loopSlots (RReuseOffer fc sc dupOnShared dropOnUnique body) = RReuseOffer fc sc dupOnShared dropOnUnique <$> go reps loopSlots body
    go reps loopSlots (RMemoize fc n rep body) = RMemoize fc n rep <$> go reps loopSlots body
    -- RV, RUnderApp, RApp, RCon, ROp, RExtPrim, RPrimVal, RErased,
    -- RCrash, RLoopContinue, RStructGet, RStructSet: no RCExp child to
    -- recurse into. RAppNameRep/RAppFFIInline can't exist yet --
    -- Compiler.RC2.DualABI runs strictly after this pass.
    go _ _ e = pure e

    -- Manual case split, not `traverse` -- `Core` has no `Applicative`
    -- instance (`Core.Core`'s own `<$>`/`<*>` above are ad-hoc
    -- functions, not a real instance `Prelude.traverse` could resolve
    -- against), so `traverse`'s generic `Maybe` case doesn't apply.
    goMaybe : SortedMap Int Rep -> List (Int, Rep) -> Maybe RCExp -> Core (Maybe RCExp)
    goMaybe _ _ Nothing = pure Nothing
    goMaybe reps loopSlots (Just e) = Just <$> go reps loopSlots e

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
