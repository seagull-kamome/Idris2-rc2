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

||| `True` iff `target` has an occurrence in `e` not accounted for by
||| a native-operand read at type `ty`, nor by ownership bookkeeping
||| `Compiler.RC2.Loop`'s own `stripOwnership` would strip anyway
||| (`RDup`/`RDrop`/`RFree`, any node's own `postDrop`). `loopSlots`:
||| the nearest enclosing `RLoop`'s own `loopParams` -- an
||| `RLoopContinue` entry at a position whose slot is already declared
||| `RNative ty` is safe too, since `Emit.idr`'s `tryEmitLoopContinue`
||| always renders a continue's new value keyed on *that slot's* `Rep`,
||| never the supplied value's. See `rc2/doc/inlining.md`'s "Criterion
||| B, revisited" for the full design and the bugs this prevents.
hasNonNativeUse : (ty : PrimType) -> (loopSlots : List (Int, Rep)) -> Int -> RCExp -> Bool
hasNonNativeUse ty loopSlots target (RV _ v) = v == RCLoc target
hasNonNativeUse ty loopSlots target (RAppName _ _ _ args) = elem (RCLoc target) args
hasNonNativeUse ty loopSlots target (RUnderApp _ _ _ args) = elem (RCLoc target) args
hasNonNativeUse ty loopSlots target (RApp _ _ c a) = c == RCLoc target || a == RCLoc target
hasNonNativeUse ty loopSlots target (RLet _ _ _ value body) =
    hasNonNativeUse ty loopSlots target value || hasNonNativeUse ty loopSlots target body
hasNonNativeUse ty loopSlots target (RCon _ _ _ _ args reuseFrom) = elem (RCLoc target) args || reuseFrom == Just (RCLoc target)
hasNonNativeUse ty loopSlots target (ROp {}) = False -- postDrop-only; stale, stripOwnership handles it
hasNonNativeUse ty loopSlots target (RExtPrim _ _ _ args postDrop) = elem (RCLoc target) args || elem (RCLoc target) postDrop
-- Unlike ROp/RCmpCase/..., stripOwnership never touches RExtPrim's own postDrop -- a genuine use here.
hasNonNativeUse ty loopSlots target (RStructGet _ structVar _ _ _) = structVar == RCLoc target
hasNonNativeUse ty loopSlots target (RStructSet _ structVar _ _ value _) = structVar == RCLoc target || value == RCLoc target
hasNonNativeUse ty loopSlots target (RCmpCase _ _ _ _ t f) = hasNonNativeUse ty loopSlots target t || hasNonNativeUse ty loopSlots target f
hasNonNativeUse ty loopSlots target (RConCase _ sc alts mDef) =
    sc == RCLoc target || any (\(MkRConAlt _ _ _ _ body) => hasNonNativeUse ty loopSlots target body) alts
      || maybe False (hasNonNativeUse ty loopSlots target) mDef
hasNonNativeUse ty loopSlots target (RConstCase _ sc alts mDef) =
    sc == RCLoc target || any (\(MkRConstAlt _ body) => hasNonNativeUse ty loopSlots target body) alts
      || maybe False (hasNonNativeUse ty loopSlots target) mDef
hasNonNativeUse ty loopSlots target (RDup _ v _ body) = hasNonNativeUse ty loopSlots target body
hasNonNativeUse ty loopSlots target (RDrop _ vars body) = hasNonNativeUse ty loopSlots target body
hasNonNativeUse ty loopSlots target (RFree _ v body) = hasNonNativeUse ty loopSlots target body
hasNonNativeUse ty loopSlots target (RReleaseReuse _ v body) = v == RCLoc target || hasNonNativeUse ty loopSlots target body
-- RReleaseReuse's own v / RReuseOffer's own sc/dupOnShared/dropOnUnique are genuine uses --
-- stripOwnership deliberately never touches an already-decided reuse.
hasNonNativeUse ty loopSlots target (RReuseOffer _ sc dupOnShared dropOnUnique body) =
    sc == RCLoc target || elem (RCLoc target) dupOnShared || elem (RCLoc target) dropOnUnique
      || hasNonNativeUse ty loopSlots target body
hasNonNativeUse ty loopSlots target (RLoop _ loopParams initial _ body) =
    elem (RCLoc target) initial || hasNonNativeUse ty loopParams target body
-- body is checked against THIS loop's own slots, not the enclosing loopSlots. initial is
-- conservatively treated as a genuine use regardless (see this function's own doc comment).
hasNonNativeUse ty loopSlots target (RLoopContinue _ args _) =
    any (\((_, slotRep), a) => a == RCLoc target && not (matchesTy slotRep)) (zip loopSlots args)
      || (length args /= length loopSlots && elem (RCLoc target) args)
        -- length mismatch shouldn't happen structurally; falls back to disqualifying rather
        -- than risk `zip` silently dropping a real occurrence in the tail.
  where
    matchesTy : Rep -> Bool
    matchesTy (RNative ty') = ty' == ty
    matchesTy _ = False
hasNonNativeUse ty loopSlots target (RMemoize _ _ _ body) = hasNonNativeUse ty loopSlots target body
hasNonNativeUse _ _ _ _ = False -- RPrimVal/RErased/RCrash: no locals. RAppNameRep/RAppFFIInline can't exist yet.

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
||| onto the actual call arguments, plus a wrapping function binding
||| each argument via its own `RLet` ahead of the callee's own renamed
||| body, plus every fresh id bound purely `RNative` this way (for
||| `spliceCall`'s own final `stripOwnership` pass).
|||
||| Every argument gets its own *fresh* id, even one that's already a
||| bare `RCLoc` -- never aliased directly onto the caller's own local.
||| A loop-converted callee's own `RLoop` commonly reuses its top-level
||| param's id as a *mutable* loop-carried variable, so aliasing would
||| let the splice reassign the caller's own variable in place, unlike
||| an ordinary call. The fresh id's own `Rep`: `RBoxed` unless the
||| actual argument is currently native in the caller (`reps`) *and*
||| `nativeEligible` confirms the callee's own body never needs it any
||| other way, at the same type. See `rc2/doc/inlining.md`'s "Criterion
||| B, revisited" for both bugs found getting this wrong (an aliasing
||| correctness bug, and a ~50x boxing performance regression).
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
||| Needed even though `VarId` already makes every id globally unique
||| from the moment it's first assigned: `Compiler.RC2.SpecClosure`
||| builds several clones from one shared original body, copying its
||| internal ids verbatim into every clone -- two clones legitimately
||| share ids as long as each stays its own C function, but splicing
||| two of them into the *same* caller breaks that separation. See
||| `rc2/doc/inlining.md`'s "Criterion B, revisited" for the bug this
||| was found via (`var_301` redefined in one C function).
freshenBoundIds : {auto v : Ref VarId Int} -> List Int -> Core Renaming
freshenBoundIds [] = pure empty
freshenBoundIds (i :: is) = do
    ren <- freshenBoundIds is
    f <- freshVarId
    pure (insert i f ren)

||| Whether `Emit.idr`'s own `emitNativeValue` (the single inline-C-
||| expression renderer `declareNative`/`inlineNative` use for a native
||| local's own value) can actually render `e` -- mirrors its supported
||| shapes constructor-for-constructor: `RAppFFIInline`/`ROp`/`RPrimVal`
||| at the tail, unwinding `RLet`/`RDup`/`RFree`/`RDrop`/`RReleaseReuse`
||| wrappers on the way, nothing else (in particular, no branch --
||| `RConCase`/`RConstCase`/`RCmpCase` -- and no nested `RLoop`, neither
||| of which can be one C expression). `RAppFFIInline` can't actually
||| occur in a tree this pass ever sees (`Compiler.RC2.DualABI` runs
||| strictly after this pass) but is included anyway to keep this an
||| honest mirror rather than a guess. `uniformTailType` below alone
||| isn't sufficient for a promotion decision -- it happily says "yes"
||| through a branch this function can't render -- see
||| `rc2/doc/inlining.md`'s "Criterion B, revisited" for the crash this
||| was found via.
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

||| `Just ty` iff an `RBoxed`-declared `RLet var value body` can be
||| promoted to native `Rep` `ty`: `value`'s own tail is uniformly
||| native (`uniformTailType`), `Emit.idr` can actually render it as
||| one C expression (`emitNativeValueCompatible`), and `body` itself
||| never needs `var` any other way (`hasNonNativeUse`). `loopSlots`:
||| the nearest enclosing `RLoop`'s own `loopParams`, threaded through
||| to `hasNonNativeUse`.
|||
||| Generic over how `value` came to exist -- not specific to splicing
||| -- so any pass assembling a fresh `RBoxed`-declared local (e.g. a
||| clone `Compiler.RC2.SpecClosure` builds) can reuse this to redo
||| native-Rep promotion over the result. See `rc2/doc/inlining.md`'s
||| "Criterion B, revisited" (Layer 2/3) for why this check exists.
export
promotableNativeLetRep : (loopSlots : List (Int, Rep)) -> (var : Int) -> (value : RCExp) -> (body : RCExp) -> Maybe PrimType
promotableNativeLetRep loopSlots var value body =
    case uniformTailType value of
         Just ty => if emitNativeValueCompatible value && not (hasNonNativeUse ty loopSlots var body) then Just ty else Nothing
         Nothing => Nothing

||| Replace one fully-saturated call to an eligible callee with its own
||| (renamed) body. `reps`: the caller's own current `Rep` environment
||| at this exact call site (`inlineInto`'s own walk), consulted by
||| `buildSplice` above -- never the callee's own originally-declared
||| param `Rep`.
spliceCall : {auto v : Ref VarId Int} -> FC -> SortedMap Int Rep -> RCDef -> List RCLocal -> Core RCExp
spliceCall fc reps (MkRCFun calleeArgs _ _ calleeBody) actualArgs = do
    (paramRen, wrap, promoted) <- buildSplice fc reps calleeBody (zipArgs (map fst calleeArgs) actualArgs)
    let paramIds = SortedSet.fromList (map fst calleeArgs)
    internalRen <- freshenBoundIds (filter (\i => not (contains i paramIds)) (collectBoundIds calleeBody))
    let ren = foldl (\acc, (k, val) => insert k val acc) paramRen (SortedMap.toList internalRen)
    -- `promoted` names post-rename ids declared purely `RNative` above
    -- (a value type is never refcounted, so nothing left to
    -- reannotate) -- unlike `Compiler.RC2.ConAltNative`'s own fuller
    -- native-shadow promotion, where a field can still have a
    -- *surviving* Boxed-context use.
    pure $ wrap (stripOwnership promoted (renameRCExp ren calleeBody))
  where
    zipArgs : List Int -> List RCLocal -> List (Int, RCLocal)
    zipArgs (i :: is) (a :: as) = (i, a) :: zipArgs is as
    zipArgs _ _ = []
-- Defensive only -- `eligible` (built from `isFun` in `analyse`) never
-- names anything but a `MkRCFun`.
spliceCall _ _ d _ = pure $ RCrash EmptyFC "[rc2] internal: LateInline target wasn't a MkRCFun"

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
    -- enclosing* `RLoop`'s own `loopParams` (`[]` outside any loop),
    -- set at `go`'s own RLoop case below -- threaded separately from
    -- `reps` because it must reflect a loop `go`'s own outer recursion
    -- already walked through, not just one reachable from the current
    -- subtree. See `rc2/doc/inlining.md`'s "Criterion B, revisited"
    -- (Layer 3) for the regression a hardcoded `[]` here reproduces.
    go : SortedMap Int Rep -> List (Int, Rep) -> RCExp -> Core RCExp
    go reps loopSlots (RAppName fc lazy n args) =
        if contains n eligible
           then case lookup n defOf of
                     Just d => spliceCall fc reps d args
                     Nothing => pure (RAppName fc lazy n args)
           else pure (RAppName fc lazy n args)
    -- The call sits directly as an `RLet`'s own still-`RBoxed` value
    -- (the shape an ordinary, not-yet-`Compiler.RC2.DualABI`-touched
    -- call site always has) -- `promotableNativeLetRep` decides
    -- whether `var`'s own declaration can be promoted to native
    -- (return-side twin of `buildSplice`'s own argument-side
    -- promotion above; see `rc2/doc/inlining.md`, Layer 2/3, for the
    -- measured cost of not doing this).
    go reps loopSlots (RLet fc var RBoxed value@(RAppName vfc lazy n args) body) =
        if contains n eligible
           then case lookup n defOf of
                     Just d => do
                         splicedValue <- spliceCall vfc reps d args
                         case promotableNativeLetRep loopSlots var splicedValue body of
                              Just ty => do
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
