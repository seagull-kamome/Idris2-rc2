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

import Compiler.RC2.DeadCode
import Compiler.RC2.DualABI
import Compiler.RC2.Loop
import Compiler.RC2.MutualLoop
import Compiler.RC2.RCExp
import Compiler.RC2.Types
import Compiler.RC2.Util

import Core.Context
import Core.Context.Log
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

||| One name's own `(calleesOf, callOccurrencesOf)`, cached across
||| `applyLateInline`'s own rounds -- see `analyse`'s own doc comment
||| for why a name absent from one round's own `dirty` set is always
||| safe to reuse here verbatim, no matter how many further rounds
||| pass, right up until it's actually reprocessed.
CalleeInfo : Type
CalleeInfo = SortedMap Name (SortedSet Name, List Name)

record Analysis where
  constructor MkAnalysis
  ||| Every eligible callee: exactly one call site anywhere, and a
  ||| genuine `MkRCFun` (not `RCCon`/`RCForeign`/`RCError`). Being part
  ||| of a whole-program cycle (a size>=2 SCC, or a direct self-edge)
  ||| does *not* disqualify a callee on its own anymore --
  ||| `callsBack`, consulted by `inlineInto` fresh at each individual
  ||| splice decision, is what replaces that. See `rc2/doc/inlining.md`'s
  ||| "Safe despite being part of a larger cycle" for the full argument.
  eligible : SortedSet Name
  ||| Every name, callees before callers where the call graph orders
  ||| them at all (`tarjanSCCs`'s own bottom-up ordering, reused
  ||| verbatim from `Compiler.RC2.MutualLoop` -- see the doc for why
  ||| this lets a whole *chain* of single-caller callees collapse in
  ||| one pass instead of needing to be re-run per link).
  processOrder : List Name

||| Everything `analyse` carries from one `applyLateInline` round into
||| the next, so a round only pays for whatever actually changed since
||| the last one. `Nothing` on the first round (nothing carried yet).
record Carried where
  constructor MkCarried
  ||| Per-name callee info (see `CalleeInfo`).
  info : CalleeInfo
  ||| Whole-program `RAppName` occurrence count per name -- maintained
  ||| by delta from round to round rather than re-summed from every
  ||| definition's own occurrence list, which was this pass's single
  ||| largest cost at whole-compiler scale (~5.7s per round on
  ||| `idris2-lsp`: ~118k `insertWith`s into a `Name`-keyed map, whose
  ||| comparisons are structural over namespace lists and strings).
  ||| Only two things can shift a count: a definition whose own body
  ||| changed (`dirty`, its old occurrence list subtracted and its new
  ||| one added) and a definition pruned away entirely (its old
  ||| occurrence list subtracted). Both are read straight off `info`,
  ||| which still holds the pre-change entry at that point.
  counts : SortedMap Name Nat
  ||| `tarjanSCCs`-derived callee-before-caller processing order,
  ||| computed once on the first round and reused verbatim afterwards.
  ||| Safe because this order is only ever a *heuristic* -- it decides
  ||| whether a chain of single-caller callees collapses in one round
  ||| or needs a further one, never what the result is -- and because
  ||| `defs` only shrinks, so a later round's own names are always a
  ||| subset of what this order already covers; `goOrder` skips a name
  ||| it no longer finds in `defOf`.
  order : List Name
  ||| The previous round's own definition names -- what "pruned away
  ||| since last round" is spotted against, for the count delta above.
  names : List Name

||| `cache`: every name's own `CalleeInfo` as of the last round it was
||| actually reprocessed (`empty` on the very first round). `dirty`:
||| the *previous* round's own processed set (`empty` on the first
||| round too) -- a name absent from it has a body byte-for-byte
||| identical to last round's (the only way a name's body ever changes
||| during `applyLateInline` is `goOrder` actually splicing something
||| into it -- `pruneDeadDefs` only ever *removes* names, never rewrites
||| a survivor), so its own `calleesOf`/`callOccurrencesOf` contribution
||| is still exactly correct and safe to reuse straight from `cache`
||| rather than re-walking its own (possibly large) body. Every name in
||| `defs` gets a `cache` entry either way (freshly computed the first
||| time it's ever seen, or whenever `dirty` says it changed) -- `defs`
||| only ever shrinks round-to-round (`pruneDeadDefs`), so a name
||| in `defs` on round N+1 was necessarily in `defs`, and thus already
||| cached, on round N. Returns the updated cache alongside the
||| `Analysis` as before, for `applyLateInlineOnce` to thread into the
||| next round.
analyse : (prev : Maybe Carried) -> (dirty : SortedSet Name) -> List (Name, RCDef) -> (Analysis, Carried)
analyse prev dirty defs =
    let oldInfo : CalleeInfo = maybe empty (.info) prev
        defOf : SortedMap Name RCDef = SortedMap.fromList defs
        perDef : List (Name, (SortedSet Name, List Name)) =
                   map (\(n, d) =>
                          (n, case lookup n oldInfo of
                                   Just i => if contains n dirty then freshInfo d else i
                                   Nothing => freshInfo d)) defs
        info' : CalleeInfo = foldl (\acc, (n, i) => insert n i acc) oldInfo perDef
        counts' : SortedMap Name Nat = case prev of
                 Nothing => foldl (\acc, n => insertWith (+) n 1 acc) (the (SortedMap Name Nat) empty)
                              (concatMap (\(_, (_, occs)) => occs) perDef)
                 Just p => deltaCounts p defOf info'
        order' : List Name = case prev of
                 Nothing => reverse (concat (tarjanSCCs (SortedMap.fromList (map (\(n, (cs, _)) => (n, cs)) perDef))))
                 Just p => p.order
        eligible : SortedSet Name = SortedSet.fromList $ mapMaybe
              (\(n, cnt) => if cnt == 1 && isFun defOf n then Just n else Nothing)
              (SortedMap.toList counts')
    in (MkAnalysis eligible order', MkCarried info' counts' order' (map fst defs))
  where
    freshInfo : RCDef -> (SortedSet Name, List Name)
    freshInfo d = (calleesOf d, callOccurrencesOf d)

    isFun : SortedMap Name RCDef -> Name -> Bool
    isFun defOf n = case lookup n defOf of
                         Just (MkRCFun _ _ _ _) => True
                         _ => False

    occsOf : CalleeInfo -> Name -> List Name
    occsOf ci n = maybe [] snd (lookup n ci)

    dec : SortedMap Name Nat -> Name -> SortedMap Name Nat
    dec m n = case lookup n m of
                   Just c => if c <= 1 then delete n m else insert n (minus c 1) m
                   Nothing => m

    inc : SortedMap Name Nat -> Name -> SortedMap Name Nat
    inc m n = insertWith (+) n 1 m

    ||| `prev.counts` adjusted for exactly the two things that can have
    ||| shifted a count since it was built: a name pruned away (its own
    ||| calls are gone with it) and a name `dirty` says was spliced into
    ||| last round (its old call list replaced by its new one). Both
    ||| read their *old* list from `prev.info`, which still holds the
    ||| pre-change entry -- `newInfo` is where the fresh one lives.
    deltaCounts : Carried -> SortedMap Name RCDef -> CalleeInfo -> SortedMap Name Nat
    deltaCounts p defOf newInfo =
        let gone : List Name = filter (\n => isNothing (lookup n defOf)) p.names
            afterGone : SortedMap Name Nat =
                foldl (\acc, n => foldl dec acc (occsOf p.info n)) p.counts gone
            changed : List Name = filter (\n => isJust (lookup n defOf)) (Prelude.toList dirty)
        in foldl (\acc, n => foldl inc (foldl dec acc (occsOf p.info n)) (occsOf newInfo n))
             afterGone changed

||| Whether `callee`'s own body (looked up in `defOf`) directly calls
||| `caller` -- checked fresh at each individual splice decision
||| (`inlineInto`'s own `RAppName` cases), rather than once, whole-
||| program, via `analyse`'s own (removed) cyclic-SCC exclusion. See
||| `rc2/doc/inlining.md`'s "Safe despite being part of a larger cycle"
||| for the full argument: why this one-hop check is sufficient (no
||| deeper, transitive check ever needed), and why it isn't even
||| load-bearing for runtime correctness -- only for keeping
||| `applyLateInline`'s own fixpoint-loop bookkeeping simple.
callsBack : SortedMap Name RCDef -> (caller : Name) -> (callee : Name) -> Bool
callsBack defOf caller callee =
    case lookup callee defOf of
         Just d => contains caller (calleesOf d)
         Nothing => False

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
hasNonNativeUse ty loopSlots target (RApp _ _ c args) = c == RCLoc target || elem (RCLoc target) args
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

||| Whether `target` is reused anywhere in `e` as one of an `RLoop`'s
||| own loop-carried slot ids (`loopParams`' own `Int`) -- i.e. whether
||| aliasing the caller's own local for `target` straight into the
||| splice risks that local being reassigned in place by the loop,
||| rather than only read. Mirrors `collectBoundIds`'s own traversal
||| shape. See `buildSplice`'s own doc comment for why only this one
||| case still needs a fresh id and a wrapping `RLet`.
isLoopCarried : Int -> RCExp -> Bool
isLoopCarried target (RLoop _ loopParams _ _ body) = elem target (map fst loopParams) || isLoopCarried target body
isLoopCarried target (RLet _ _ _ value body) = isLoopCarried target value || isLoopCarried target body
isLoopCarried target (RCmpCase _ _ _ _ t f) = isLoopCarried target t || isLoopCarried target f
isLoopCarried target (RConCase _ _ alts mDef) =
    any (\(MkRConAlt _ _ _ _ body) => isLoopCarried target body) alts || maybe False (isLoopCarried target) mDef
isLoopCarried target (RConstCase _ _ alts mDef) =
    any (\(MkRConstAlt _ body) => isLoopCarried target body) alts || maybe False (isLoopCarried target) mDef
isLoopCarried target (RDup _ _ _ body) = isLoopCarried target body
isLoopCarried target (RDrop _ _ body) = isLoopCarried target body
isLoopCarried target (RFree _ _ body) = isLoopCarried target body
isLoopCarried target (RReleaseReuse _ _ body) = isLoopCarried target body
isLoopCarried target (RReuseOffer _ _ _ _ body) = isLoopCarried target body
isLoopCarried target (RMemoize _ _ _ body) = isLoopCarried target body
isLoopCarried _ _ = False

||| Builds the renaming from `calleeArgs`'s own top-level param ids
||| onto the actual call arguments, plus a wrapping function binding
||| each argument that still needs its own declaration via `RLet`
||| ahead of the callee's own renamed body, plus every fresh id bound
||| purely `RNative` this way (for `spliceCall`'s own final
||| `stripOwnership` pass).
|||
||| An argument already `RBoxed` in the caller (`reps`) whose param id
||| is never reused as one of `calleeBody`'s own loop-carried slots
||| (`isLoopCarried`) is aliased directly onto the caller's own local
||| instead -- no fresh id, no wrapping `RLet` -- since both sides
||| already share the exact same representation and nothing in the
||| callee can reassign it out from under the caller. Every other
||| argument still gets its own *fresh* id, even one that's already a
||| bare `RCLoc`: either it's boxed but loop-carried (aliasing would
||| let the splice reassign the caller's own variable in place, unlike
||| an ordinary call -- see `rc2/doc/inlining.md`'s "Criterion B,
||| revisited" for the bug this prevents), or it's currently native in
||| the caller, where the fresh `RLet`'s own `Rep` -- `RNative ty`
||| unless the actual argument is currently native in the caller
||| (`reps`) *and* `nativeEligible` confirms the callee's own body
||| never needs it any other way, at the same type -- is the
||| boxing/promotion decision itself, not a redundant copy of already-
||| identical representations. See `rc2/doc/inlining.md`'s "Criterion
||| B, revisited" for both bugs found getting the native side of this
||| wrong (an aliasing correctness bug, and a ~50x boxing performance
||| regression).
buildSplice : {auto v : Ref VarId Int} -> FC -> SortedMap Int Rep -> RCExp -> List (Int, RCLocal) -> Core (Renaming, RCExp -> RCExp, SortedSet Int)
buildSplice fc reps calleeBody [] = pure (empty, id, empty)
buildSplice fc reps calleeBody ((paramId, actual@(RCLoc actualId)) :: rest) = do
    (ren, wrap, promoted) <- buildSplice fc reps calleeBody rest
    case argRep reps actual of
         RNative ty => do
             f <- freshVarId
             let (rep, promoted') = case nativeEligible paramId calleeBody of
                                          Just ty' => if ty' == ty then (RNative ty, SortedSet.insert f promoted) else (RBoxed, promoted)
                                          Nothing => (RBoxed, promoted)
             pure (insert paramId f ren, wrap . RLet fc f rep (RV fc actual), promoted')
         _ => if isLoopCarried paramId calleeBody
                 then do
                     f <- freshVarId
                     pure (insert paramId f ren, wrap . RLet fc f RBoxed (RV fc actual), promoted)
                 else pure (insert paramId actualId ren, wrap, promoted)
  where
    argRep : SortedMap Int Rep -> RCLocal -> Rep
    argRep reps (RCLoc j) = case lookup j reps of
                                 Just (RInlineNative ty) => RNative ty
                                 Just r => r
                                 Nothing => RBoxed
    argRep _ _ = RBoxed
-- `actual` isn't a bare `RCLoc` (a constant/`RCEmptyCon`/`RCConstCon`/
-- `RCConstClosure` folded by `Compiler.RC2.ConstFold`) -- no existing
-- caller local to alias onto or promote, so this always needs its own
-- fresh `RBoxed` declaration exactly as before.
buildSplice fc reps calleeBody ((paramId, actual) :: rest) = do
    (ren, wrap, promoted) <- buildSplice fc reps calleeBody rest
    f <- freshVarId
    pure (insert paramId f ren, wrap . RLet fc f RBoxed (RV fc actual), promoted)

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
|||
||| `self`: the name of the one definition whose body this call is
||| walking (`goOrder`'s own `n`) -- consulted, via `callsBack`, at
||| every `RAppName` this walk finds, to refuse splicing a callee that
||| directly calls `self` back. See `callsBack`'s own doc comment.
inlineInto : {auto v : Ref VarId Int} -> SortedMap Name RCDef -> SortedSet Name -> (self : Name) -> RCExp -> Core RCExp
inlineInto defOf eligible self = go empty []
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
        if contains n eligible && not (callsBack defOf self n)
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
        if contains n eligible && not (callsBack defOf self n)
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

||| One pass over the whole program: first drops anything already
||| unreachable from `roots` (`Compiler.RC2.DeadCode.pruneDeadDefs`,
||| reused as-is -- see this doc comment's own last paragraph for why
||| this, rather than leaving cleanup entirely to the later, separate
||| `Compiler.RC2.DeadCode` pipeline stage), then splices every
||| remaining single-caller callee (`analyse`'s own `eligible`, now
||| computed from only the still-reachable definitions) into its one
||| call site. `False` (alongside `defs` unchanged) only when pruning
||| removed nothing *and* `eligible` came back empty.
|||
||| See the doc's "Eligibility" section for why `processOrder` (not
||| `defs`'s own order) is used -- a *chain* of single-caller callees
||| already collapses fully within this one call, without needing a
||| second round, whenever the whole chain is visible to `analyse` from
||| the start.
|||
||| Pruning first, every round, is what lets `applyLateInline`'s own
||| fixpoint loop below reach a case that a bare re-run of the splice
||| step alone never would: a callee with two call sites when this
||| round's own `analyse` would otherwise run, one of them inside a
||| definition this same round is about to render (or already has
||| rendered) unreachable. Without re-pruning first, that stale call
||| site -- still physically present in `defs`, `analyse`'s own
||| `callCounts` blind to whether anything still reachable actually
||| runs it -- would keep the callee looking "more than one caller"
||| forever, no matter how many further rounds ran; `roots`-driven
||| dead-code removal is the only thing that can tell "still called"
||| apart from "called only from code nothing reaches anymore."
|||
||| Deliberately not a replacement for the later, separate
||| `Compiler.RC2.DeadCode.pruneDeadDefs roots` call after `DualABI` --
||| that one has its own job (`DualABI` runs after this pass entirely
||| and can introduce fresh dead weight of its own, e.g. an unused
||| worker/wrapper split, that this pass can never see) and stays
||| exactly where it is.
|||
||| `prev`/`dirty`: threaded straight through to `analyse` (see its
||| own doc comment) -- `applyLateInline`'s own fixpoint loop carries
||| the returned `Carried` and this round's own `toProcess` (the *only*
||| names `goOrder` below is ever handed) into the next round's call.
|||
||| **The two `logTime`s here each open with `() <- pure ()` on
||| purpose, and removing that would silently break them**: everything
||| they wrap is a *pure* `let`, and in a strict language the argument
||| expression is fully evaluated before `logTime` is ever entered, so
||| a bare `logTime lvl str $ pure (heavyPureThing)` clocks nothing but
||| the `pure`. Binding once first pushes the real work into the
||| continuation, which only runs inside the timed region. This is not
||| hypothetical: `analyse`'s own ~10s-per-round cost hid behind
||| exactly that mistake here for an entire investigation, reported as
||| a ~0.1s round while `"rc2: Late inline"` sat at ~45s.
|||
||| **Only walking `toProcess`, not every name in `processOrder`**: the
||| overwhelming majority of a real whole-program def list never calls
||| anything `eligible` at all, in any given round, yet the pre-cache
||| version of this pass ran `inlineInto`'s own full structural
||| walk-and-rebuild over *every one* of them anyway, every round, only
||| to reconstruct an identical tree. `Carried.info` already has each
||| name's own callee set -- checking it against `eligible` costs one
||| membership test per callee, nowhere near the cost of walking that
||| name's own (possibly huge) body. Found against a real build
||| (`idris2-lsp`, `--timing 2`), whose
||| whole-program def list is large enough (compiler-plus-LSP-server
||| scale) to make the pre-caching version's blanket walk dominate
||| `"rc2: Late inline"`'s own wall-clock cost outright.
applyLateInlineOnce : {auto v : Ref VarId Int} -> {auto c : Ref Ctxt Defs} -> (roots : List Name) -> Maybe Carried -> SortedSet Name -> List (Name, RCDef) -> Core (Bool, List (Name, RCDef), Carried, SortedSet Name)
applyLateInlineOnce roots prev dirty defs0 = do
    defs <- logTime 3 "rc2: LI prune" $ do
              () <- pure ()
              let d : List (Name, RCDef) = pruneDeadDefs roots defs0
              let n : Nat = length d
              pure (if n == n then d else d)
    (an, carried) <- logTime 3 "rc2: LI analyse" $ do
              () <- pure ()
              let r : (Analysis, Carried) = analyse prev dirty defs
              let n : Nat = length (Prelude.toList (fst r).eligible)
                              + length (snd r).order
                              + length (SortedMap.toList (snd r).counts)
              pure (if n == n then r else r)
    case leftMost an.eligible of
         Nothing => pure (length defs /= length defs0, defs, carried, empty)
         Just _ => do
             -- Walks the *small* side (this one name's own, typically
             -- tiny, callee set) doing an `eligible` membership check
             -- per callee, rather than `intersection cs an.eligible`
             -- (whose own cost -- depending on `Data.SortedSet`'s
             -- implementation -- may scale with *both* sides, `eligible`
             -- included; `eligible` can itself be large on an early
             -- round of a big program, and this check runs once per
             -- name in `processOrder`, so paying per-`eligible`-size
             -- cost here, not just per-`cs`-size, would undo the whole
             -- point of filtering to `toProcess` in the first place).
             let touchesEligible : Name -> Bool
                 touchesEligible n = case lookup n carried.info of
                                           Just (cs, _) => any (\c => contains c an.eligible) (Prelude.toList cs)
                                           Nothing => False
             let toProcess = filter touchesEligible an.processOrder
             final <- goOrder an.eligible toProcess (SortedMap.fromList defs)
             pure (True, map (\(n, d) => (n, fromMaybe d (lookup n final))) defs, carried, SortedSet.fromList toProcess)
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

||| Iteration cap for `applyLateInline`'s own whole-program fixpoint
||| loop -- same rationale as `RC2.idr`'s own `maxConstFoldIterations`
||| for `foldConstProgram` (chosen the same value, 4, for the same
||| reason: GHC's own `-fmax-simplifier-iterations` default). Each
||| round's own `eligible` set can only ever shrink -- a callee spliced
||| away this round drops to call count 0 and can never regain
||| eligibility -- so the loop already halts on its own the moment
||| nothing is left to splice; this cap only guards a pathological
||| input from iterating unboundedly.
maxLateInlineIterations : Nat
maxLateInlineIterations = 4

||| Runs `applyLateInlineOnce` repeatedly (`roots`: same whole-program
||| entry points `Compiler.RC2.DeadCode.pruneDeadDefs` itself is always
||| called with -- see that function's own doc comment for why each
||| round re-prunes with it first) -- see `applyLateInlineOnce`'s own
||| doc comment for when a further round actually finds something new
||| to do -- until a round finds nothing left to prune or splice, or
||| `maxLateInlineIterations` is reached, whichever comes first.
|||
||| Each round is individually `logTime`d at the finer `--timing 3`
||| level, on top of the aggregate `"rc2: Late inline"` timer `RC2.idr`'s
||| own pipeline already wraps the whole call in (same
||| coarser/finer-level split `RC2.idr`'s own "Loop conversion"/"Loop
||| conversion (apply)" pair already uses) -- a round-by-round
||| breakdown is what distinguishes "cost scales with fixed round
||| count" from "cost grows round-over-round as earlier rounds' own
||| splices inflate what later rounds have to re-`analyse`/re-walk",
||| which the aggregate number alone can't tell apart, and is also
||| exactly what surfaced `analyse`/`applyLateInlineOnce`'s own
||| `CalleeInfo` cache and `toProcess` filter as worth adding in the
||| first place (found against a real build, `idris2-lsp` -- see
||| `applyLateInlineOnce`'s own doc comment).
|||
||| `cache`/`dirty` start `empty` on round 1 (nothing cached, nothing to
||| treat as unchanged-since-last-round yet) and thread the previous
||| round's own returned cache/`toProcess` into the next.
|||
||| **Open gap, not yet explained**: the `CalleeInfo` cache and
||| `toProcess` filter above cut each individual round's own measured
||| cost to a small fraction of a second against a real build
||| (`idris2-lsp`) -- round 2 through 4 each ~0.1s, down from the
||| whole pass's own former ~46s aggregate. Yet that *aggregate*
||| `"rc2: Late inline"` number barely moved. Explicitly forcing every
||| value this loop threads between rounds (`defs'`, `cache'`, and the
||| `looped` argument this function is first called with) came back
||| cheap too, each under a tenth of a second -- ruling out a deferred/
||| thunked computation (expected: Idris2/Chez evaluation is strict
||| here, `Core`'s own `<-` genuinely runs its action once). Raw
||| `System.Clock` timestamps taken immediately around this whole
||| function's own call confirmed the ~45s is real wall/process time,
||| not a `logTime` measurement artifact. Suspected but not confirmed:
||| GC pressure from the repeated whole-program `SortedMap`/`SortedSet`
||| reconstruction, landing its cost somewhere `logTime`'s own
||| before/after clock reads don't happen to bracket -- not yet
||| confirmed (no GC-specific counter checked against this directly).
export
applyLateInline : {auto v : Ref VarId Int} -> {auto c : Ref Ctxt Defs} -> (roots : List Name) -> List (Name, RCDef) -> Core (List (Name, RCDef))
applyLateInline roots defs0 = go 1 maxLateInlineIterations Nothing empty defs0
  where
    go : Nat -> Nat -> Maybe Carried -> SortedSet Name -> List (Name, RCDef) -> Core (List (Name, RCDef))
    go round Z prev dirty defs = pure defs
    go round (S fuel) prev dirty defs = do
        (changed, defs', carried, dirty') <- logTime 3 "rc2: Late inline (round \{show round})" $ applyLateInlineOnce roots prev dirty defs
        if changed then go (S round) fuel (Just carried) dirty' defs' else pure defs'
