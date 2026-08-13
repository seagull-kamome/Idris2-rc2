module Compiler.RC2.Loop

-- Self-tail-call loop conversion: a dedicated pass, mirroring
-- Compiler.RC2.Reuse's own place in the pipeline (runs on the fully
-- Phase-1+2'd, Reuse'd tree, right before Compiler.RC2.Emit -- see
-- RC2.idr's toRCDefs). Where Reuse looks for constructor-reuse
-- opportunities, this pass looks for a function's own self-recursive
-- tail calls and, if it finds any, wraps the whole body in one explicit
-- `RLoop` (see its own doc comment in RCExp.idr), rewriting each
-- self-call found from a generic (closure-build + boxed-trampoline)
-- `RAppName` into an `RLoopContinue`. Compiler.RC2.Emit lowers `RLoop`
-- to a `TYPE var_N` declaration per loop param (its own `Rep`,
-- independent of the function's own always-Boxed calling convention)
-- plus a `loop:;` label, and `RLoopContinue` to reassigning those loop
-- params and a plain C `goto` back to the top -- no closure allocation,
-- no trampoline dispatch, per iteration.
--
-- Besides that wrapping, this pass also decides which loop params (if
-- any) are worth promoting from `RBoxed` to a native shadow: for each
-- of the function's own top-level parameters, if the (rewritten) body
-- reads it as a native-context operand (an `RLet`-bound `RNative`/
-- `RInlineNative` `ROp`, or a fused `RCmpCase` -- the only two places
-- Compiler.RC2.Emit ever reads an operand via `rcVarToNativeC` rather
-- than `rcVarToBoxedC`, see `nativeArgTypes`) consistently at one
-- `PrimType`, a fresh loop param id is minted for it, `RNative` at that
-- type, initialised from the original (still-Boxed) parameter's value;
-- every other reference to the original parameter throughout the body
-- is redirected to the fresh shadow (`renameRCExp`), and whatever
-- Compiler.RC2.RC's `annotate` (Phase 2) had decided about the
-- *original* parameter's own dup/drop lifetime -- back when it was
-- still read from multiple Boxed-context sites -- is stripped out
-- (`stripOwnership`): a native value never needs any of that, and the
-- original parameter's own single remaining read (the shadow's own
-- initialisation, lowered by Compiler.RC2.Emit's `declareLoopParam`) is
-- its last use anywhere, dropped there instead. A parameter never read
-- natively, or read natively at more than one (conflicting) type, stays
-- `RBoxed`, reusing its own id unchanged (Compiler.RC2.Emit's
-- `declareLoopParam` then skips declaring it at all -- it's already in
-- scope, under its own exact value, as a C function parameter).
--
-- Scope: self-tail-calls only. Mutual recursion between two or more
-- functions is Compiler.RC2.MutualLoop's job -- a separate, whole-
-- program pass that runs *before* this one (see RC2.idr's toRCDefs):
-- it synthesises, for each group of mutually tail-recursive functions,
-- a single merged function whose own internal transitions (both
-- self- and cross-member) are already expressed as ordinary tail-
-- position `RAppName`s targeting *itself* -- so by the time this
-- module ever sees that merged function, converting it is just the
-- ordinary self-tail-call case below, no special-casing needed here.
-- A call wrapped in a `LazyReason` is left alone -- conservatively out
-- of scope, not investigated.
--
-- Ownership, for the wrapping step itself, is completely unaffected:
-- Compiler.RC2.RC's `annotate` (Phase 2) already decided the right
-- dup/move behaviour for the `RAppName`'s own arguments before this
-- pass ever runs, exactly as it would for a call to any other function
-- -- converting the call's *shape* doesn't change what should happen to
-- its operands. Any RDup/RDrop/RFree/RReleaseReuse wrapping the
-- `RAppName` is left in place untouched; only the terminal `RAppName`
-- node itself is ever replaced. The native-shadow promotion step is the
-- one place this pass *does* need to actively rewrite ownership
-- bookkeeping -- see `stripOwnership`'s own doc comment for why that's
-- both necessary and safe.
--
-- `collectBoundIds`/`Renaming`/`renameRCExp` below are also shared with
-- Compiler.RC2.MutualLoop's own per-member renaming (it already imports
-- this module for `mapTailAppNames`), so there is exactly one
-- definition of "walk every bound id"/"substitute every RCLocal
-- occurrence", not two kept in sync by hand.

import Compiler.RC2.RCExp
import Compiler.RC2.Types

import Core.CompileExpr
import Core.FC
import Core.TT

import Data.List
import Data.SortedMap
import Data.SortedSet
import Data.Vect

%default covering

mutual
  ||| Rewrite every tail-position, non-lazy `RAppName fc Nothing n args`
  ||| leaf of `e` for which `f fc n args` returns `Just e'`, substituting
  ||| `e'` in its place; every other leaf (including a lazy `RAppName`,
  ||| or one `f` declines by returning `Nothing`) is left untouched.
  ||| "Tail position" here is the exact same structural set
  ||| Compiler.RC2.Emit's TailPositionStatus threading already visits
  ||| when lowering to C -- RLet's body; RDup/RDrop/RFree/
  ||| RReleaseReuse/RReuseOffer's continuation; RCmpCase's two branches;
  ||| RConCase/RConstCase's alts and default. Operand positions (RCon's
  ||| args, ROp's operands, RApp's own callee/arg, an RAppName's *own*
  ||| arguments, ...) are never visited: a call sitting there isn't in
  ||| tail position and must keep going through the ordinary calling
  ||| convention regardless of what `f` would have said about it.
  |||
  ||| Defined once and shared by Compiler.RC2.Loop (`f` matches only the
  ||| enclosing function's own name) and Compiler.RC2.MutualLoop (`f`
  ||| matches any member of a whole mutually-recursive group) so the
  ||| two passes can't disagree about what "tail position" means --
  ||| that would be a real correctness risk (either pass converting or
  ||| skipping a call the other pass's own TailPositionStatus-driven
  ||| emission logic wouldn't agree is a tail position). Returns
  ||| whether any replacement was made, alongside the (possibly
  ||| rewritten) tree.
  export
  mapTailAppNames : (FC -> Name -> List RCLocal -> Maybe RCExp) -> RCExp -> (Bool, RCExp)
  mapTailAppNames f (RAppName fc Nothing n args) =
      case f fc n args of
           Just e' => (True, e')
           Nothing => (False, RAppName fc Nothing n args)
  mapTailAppNames f (RLet fc var rep value body) =
      let (found, body') = mapTailAppNames f body
      in (found, RLet fc var rep value body')
  mapTailAppNames f (RDup fc v cont) =
      let (found, cont') = mapTailAppNames f cont
      in (found, RDup fc v cont')
  mapTailAppNames f (RDrop fc vs cont) =
      let (found, cont') = mapTailAppNames f cont
      in (found, RDrop fc vs cont')
  mapTailAppNames f (RFree fc v cont) =
      let (found, cont') = mapTailAppNames f cont
      in (found, RFree fc v cont')
  mapTailAppNames f (RReleaseReuse fc v cont) =
      let (found, cont') = mapTailAppNames f cont
      in (found, RReleaseReuse fc v cont')
  mapTailAppNames f (RReuseOffer fc sc dupOnShared cont) =
      let (found, cont') = mapTailAppNames f cont
      in (found, RReuseOffer fc sc dupOnShared cont')
  mapTailAppNames f (RCmpCase fc op args postDrop t g) =
      let (foundT, t') = mapTailAppNames f t
          (foundG, g') = mapTailAppNames f g
      in (foundT || foundG, RCmpCase fc op args postDrop t' g')
  mapTailAppNames f (RConCase fc sc alts mDef) =
      let altsR = map (mapTailAppNamesAlt f) alts
          (foundDef, mDef') = mapTailAppNamesMaybe f mDef
      in (any fst altsR || foundDef, RConCase fc sc (map snd altsR) mDef')
  mapTailAppNames f (RConstCase fc sc alts mDef) =
      let altsR = map (mapTailAppNamesConstAlt f) alts
          (foundDef, mDef') = mapTailAppNamesMaybe f mDef
      in (any fst altsR || foundDef, RConstCase fc sc (map snd altsR) mDef')
  -- Every other shape (RV, RUnderApp, RApp, RCon, ROp, RExtPrim,
  -- RPrimVal, RErased, RCrash, RLoop, RLoopContinue, and a *lazy*
  -- RAppName) is either not a tail position at all or already outside
  -- any tail-rewrite pass' scope -- left untouched, no replacement.
  -- (RLoop/RLoopContinue specifically: this pass never runs on a tree
  -- that already contains one -- Compiler.RC2.Loop is the sole producer
  -- and runs at most once per definition -- so there is nothing to
  -- recurse into there in practice.)
  mapTailAppNames _ e = (False, e)

  mapTailAppNamesAlt : (FC -> Name -> List RCLocal -> Maybe RCExp) -> RConAlt -> (Bool, RConAlt)
  mapTailAppNamesAlt f (MkRConAlt name ci tag args body) =
      let (found, body') = mapTailAppNames f body
      in (found, MkRConAlt name ci tag args body')

  mapTailAppNamesConstAlt : (FC -> Name -> List RCLocal -> Maybe RCExp) -> RConstAlt -> (Bool, RConstAlt)
  mapTailAppNamesConstAlt f (MkRConstAlt c body) =
      let (found, body') = mapTailAppNames f body
      in (found, MkRConstAlt c body')

  mapTailAppNamesMaybe : (FC -> Name -> List RCLocal -> Maybe RCExp) -> Maybe RCExp -> (Bool, Maybe RCExp)
  mapTailAppNamesMaybe f Nothing = (False, Nothing)
  mapTailAppNamesMaybe f (Just e) =
      let (found, e') = mapTailAppNames f e
      in (found, Just e')

------------------------------------------------------------------------
-- Collecting every locally-bound id in a body (RLet's own var,
-- RConAlt's own destructured args) -- everything a renaming
-- substitution needs to cover, besides a definition's own top-level
-- parameters (handled separately by each caller). Visits *every*
-- reachable subexpression (an RLet's `value`, not just its `body`),
-- since a bound id can appear anywhere in the tree -- unlike
-- `mapTailAppNames` above, this is not restricted to tail positions.

mutual
  export
  collectBoundIds : RCExp -> List Int
  collectBoundIds (RLet _ var _ value body) = var :: (collectBoundIds value ++ collectBoundIds body)
  collectBoundIds (RCmpCase _ _ _ _ t f) = collectBoundIds t ++ collectBoundIds f
  collectBoundIds (RConCase _ _ alts mDef) =
      concatMap collectBoundIdsAlt alts ++ maybe [] collectBoundIds mDef
  collectBoundIds (RConstCase _ _ alts mDef) =
      concatMap collectBoundIdsConstAlt alts ++ maybe [] collectBoundIds mDef
  collectBoundIds (RDup _ _ body) = collectBoundIds body
  collectBoundIds (RDrop _ _ body) = collectBoundIds body
  collectBoundIds (RFree _ _ body) = collectBoundIds body
  collectBoundIds (RReleaseReuse _ _ body) = collectBoundIds body
  collectBoundIds (RReuseOffer _ _ _ body) = collectBoundIds body
  -- RV, RAppName, RUnderApp, RApp, RCon, ROp, RExtPrim, RPrimVal,
  -- RErased, RCrash: no subexpressions, no bindings. RLoop/
  -- RLoopContinue never actually appear here in practice either -- the
  -- only two callers (this module's own `applyLoop`, and
  -- Compiler.RC2.MutualLoop's `buildGroup`) always run before any
  -- `RLoop` exists for the tree in hand.
  collectBoundIds _ = []

  collectBoundIdsAlt : RConAlt -> List Int
  collectBoundIdsAlt (MkRConAlt _ _ _ args body) = args ++ collectBoundIds body

  collectBoundIdsConstAlt : RConstAlt -> List Int
  collectBoundIdsConstAlt (MkRConstAlt _ body) = collectBoundIds body

------------------------------------------------------------------------
-- Renaming every RCLocal/bound-id occurrence in a body according to a
-- (possibly partial -- ids with no entry pass through unchanged) map.
-- A pure substitution: doesn't add or remove any RDup/RDrop/RFree/
-- RReleaseReuse/reuse-related node, just relabels what they (and every
-- read) refer to.

public export
Renaming : Type
Renaming = SortedMap Int Int

renameId : Renaming -> Int -> Int
renameId ren i = fromMaybe i (lookup i ren)

renameLocal : Renaming -> RCLocal -> RCLocal
renameLocal ren (RCLoc i) = RCLoc (renameId ren i)
renameLocal _ l = l

renameLocals : Renaming -> List RCLocal -> List RCLocal
renameLocals ren = map (renameLocal ren)

renameLocalsV : Renaming -> Vect n RCLocal -> Vect n RCLocal
renameLocalsV ren = map (renameLocal ren)

renameMaybeLocal : Renaming -> Maybe RCLocal -> Maybe RCLocal
renameMaybeLocal ren = map (renameLocal ren)

mutual
  export
  renameRCExp : Renaming -> RCExp -> RCExp
  renameRCExp ren (RV fc v) = RV fc (renameLocal ren v)
  renameRCExp ren (RAppName fc lazy n args) = RAppName fc lazy n (renameLocals ren args)
  renameRCExp ren (RUnderApp fc n missing args) = RUnderApp fc n missing (renameLocals ren args)
  renameRCExp ren (RApp fc lazy c a) = RApp fc lazy (renameLocal ren c) (renameLocal ren a)
  renameRCExp ren (RLet fc var rep value body) =
      RLet fc (renameId ren var) rep (renameRCExp ren value) (renameRCExp ren body)
  renameRCExp ren (RCon fc n ci tag args reuseFrom) =
      RCon fc n ci tag (renameLocals ren args) (renameMaybeLocal ren reuseFrom)
  renameRCExp ren (ROp fc lazy op args postDrop) =
      ROp fc lazy op (renameLocalsV ren args) (renameLocals ren postDrop)
  renameRCExp ren (RExtPrim fc lazy p args) = RExtPrim fc lazy p (renameLocals ren args)
  renameRCExp ren (RCmpCase fc op args postDrop t f) =
      RCmpCase fc op (renameLocalsV ren args) (renameLocals ren postDrop) (renameRCExp ren t) (renameRCExp ren f)
  renameRCExp ren (RConCase fc sc alts mDef) =
      RConCase fc (renameLocal ren sc) (map (renameConAlt ren) alts) (map (renameRCExp ren) mDef)
  renameRCExp ren (RConstCase fc sc alts mDef) =
      RConstCase fc (renameLocal ren sc) (map (renameConstAlt ren) alts) (map (renameRCExp ren) mDef)
  renameRCExp _ (RPrimVal fc c) = RPrimVal fc c
  renameRCExp _ (RErased fc) = RErased fc
  renameRCExp _ (RCrash fc msg) = RCrash fc msg
  renameRCExp ren (RDup fc v body) = RDup fc (renameLocal ren v) (renameRCExp ren body)
  renameRCExp ren (RDrop fc vars body) = RDrop fc (renameLocals ren vars) (renameRCExp ren body)
  renameRCExp ren (RFree fc v body) = RFree fc (renameLocal ren v) (renameRCExp ren body)
  renameRCExp ren (RReleaseReuse fc v body) = RReleaseReuse fc (renameLocal ren v) (renameRCExp ren body)
  renameRCExp ren (RReuseOffer fc sc dupOnShared body) =
      RReuseOffer fc (renameLocal ren sc) (renameLocals ren dupOnShared) (renameRCExp ren body)
  -- Never actually reached in practice -- nothing calling this ever
  -- operates on a tree that already contains an `RLoop` (this module's
  -- own `applyLoop` is its sole producer, and only ever calls
  -- `renameRCExp` on a not-yet-wrapped body). Kept total (as a plain
  -- pass-through) rather than assumed unreachable, same reasoning as
  -- RC.idr's own `annotate`.
  renameRCExp ren (RLoop fc loopParams initial body) =
      RLoop fc (map (\(i, r) => (renameId ren i, r)) loopParams) (renameLocals ren initial) (renameRCExp ren body)
  renameRCExp ren (RLoopContinue fc args) = RLoopContinue fc (renameLocals ren args)

  renameConAlt : Renaming -> RConAlt -> RConAlt
  renameConAlt ren (MkRConAlt name ci tag args body) =
      MkRConAlt name ci tag (map (renameId ren) args) (renameRCExp ren body)

  renameConstAlt : Renaming -> RConstAlt -> RConstAlt
  renameConstAlt ren (MkRConstAlt c body) = MkRConstAlt c (renameRCExp ren body)

------------------------------------------------------------------------
-- Deciding which top-level parameters are worth a native shadow (see
-- this module's own header note), and rewriting the ownership
-- bookkeeping `Compiler.RC2.RC`'s `annotate` left behind for one once
-- it's promoted.

||| The C expression type a specific operand position of `op` needs,
||| given the enclosing `RLet`'s own native `ty` -- `p`'s contribution
||| to `nativeArgTypes` at every position it fills.
opNativeUses : (p : Int) -> PrimType -> PrimFn arity -> Vect arity RCLocal -> SortedSet PrimType
opNativeUses p ty op args =
    fromList $ mapMaybe (\a => if a == RCLoc p then Just (opArgTyFor ty op) else Nothing) (toList args)

||| `p`'s native-operand contribution (at native type `ty`, an `RLet`'s
||| own decided `Rep`) if `value` is the `ROp` that let is bound to --
||| seeing through any leading `RDup`/`RDrop`/`RFree`/`RReleaseReuse`
||| wrapping it first, the same shapes `Compiler.RC2.Emit`'s own
||| `emitNativeValue` already has to peel before it reaches the actual
||| operation (`annotate` (Phase 2) routinely wraps a multiply-used
||| operand's `RLet` value in a leading `RDup` this way, e.g. `n` here,
||| shared between this op and a later one).
opNativeUsesThrough : (p : Int) -> PrimType -> RCExp -> SortedSet PrimType
opNativeUsesThrough p ty (ROp _ _ op args _) = opNativeUses p ty op args
opNativeUsesThrough p ty (RDup _ _ cont) = opNativeUsesThrough p ty cont
opNativeUsesThrough p ty (RDrop _ _ cont) = opNativeUsesThrough p ty cont
opNativeUsesThrough p ty (RFree _ _ cont) = opNativeUsesThrough p ty cont
opNativeUsesThrough p ty (RReleaseReuse _ _ cont) = opNativeUsesThrough p ty cont
opNativeUsesThrough _ _ _ = empty

||| Every native `PrimType` at which top-level parameter `p` is read as
||| an operand of a native-result `ROp`, or of a fused `RCmpCase` -- the
||| two, and only two, places Compiler.RC2.Emit ever reads an operand
||| via `rcVarToNativeC` rather than `rcVarToBoxedC` (a Boxed-*result*
||| `ROp`'s own operands are read Boxed too, via `emitRC`'s own ROp
||| case -- only an `RLet`-bound `ROp` whose *own* `Rep` is
||| `RNative`/`RInlineNative` counts here). Walks the *whole* tree, not
||| just tail positions -- an operand can appear anywhere. A bare
||| (not-`RLet`-bound) `ROp` -- the tail value of some branch -- is
||| always emitted Boxed (see `emitInto`'s own fallback to `emitRC`), so
||| doesn't count either.
nativeArgTypes : (p : Int) -> RCExp -> SortedSet PrimType
nativeArgTypes p (RLet _ _ rep value body) =
    let fromOp = case rep of
             RNative ty => opNativeUsesThrough p ty value
             RInlineNative ty => opNativeUsesThrough p ty value
             RBoxed => empty
    in fromOp `union` (nativeArgTypes p value `union` nativeArgTypes p body)
nativeArgTypes p (RCmpCase _ op args _ t f) =
    let fromArgs = fromList $ mapMaybe (\a => if a == RCLoc p then cmpArgTy op else Nothing) (toList args)
    in fromArgs `union` (nativeArgTypes p t `union` nativeArgTypes p f)
nativeArgTypes p (RDup _ _ cont) = nativeArgTypes p cont
nativeArgTypes p (RDrop _ _ cont) = nativeArgTypes p cont
nativeArgTypes p (RFree _ _ cont) = nativeArgTypes p cont
nativeArgTypes p (RReleaseReuse _ _ cont) = nativeArgTypes p cont
nativeArgTypes p (RReuseOffer _ _ _ cont) = nativeArgTypes p cont
nativeArgTypes p (RConCase _ _ alts mDef) =
    concat (map (\(MkRConAlt _ _ _ _ body) => nativeArgTypes p body) alts)
      `union` maybe empty (nativeArgTypes p) mDef
nativeArgTypes p (RConstCase _ _ alts mDef) =
    concat (map (\(MkRConstAlt _ body) => nativeArgTypes p body) alts)
      `union` maybe empty (nativeArgTypes p) mDef
-- Every other shape (RV, RAppName, RUnderApp, RApp, RCon, a bare ROp,
-- RExtPrim, RPrimVal, RErased, RCrash, RLoopContinue -- and RLoop,
-- though it never actually appears here, this pass being its sole
-- producer): no native-context operand reads live directly in these,
-- and none hold a further RCExp to recurse into beyond what RLet/
-- RCmpCase/RConCase/RConstCase above already visit.
nativeArgTypes _ _ = empty

||| The single native `PrimType` top-level parameter `p` should be
||| shadowed at, if `body` reads it that way at all, and consistently
||| (every native-context use agrees on the same type) -- `Nothing` if
||| it's never read natively, or read natively at conflicting types
||| (conservatively left `RBoxed` rather than guessing).
nativeArgType : Int -> RCExp -> Maybe PrimType
nativeArgType p body =
    case Prelude.toList (nativeArgTypes p body) of
         [ty] => Just ty
         _ => Nothing

||| Remove every `RDup`/`RDrop`/`RFree` target, and every `ROp`/
||| `RCmpCase` `postDrop` entry, naming one of `ids` -- run right after
||| the corresponding top-level parameter(s) have been promoted to a
||| native shadow and every ordinary *value* read of them has already
||| been redirected there by `renameRCExp` (so `ids` here means the
||| *shadow* ids, post-rename, not the original parameter ids). A
||| native value never needs reference-count bookkeeping at all, so
||| whatever `annotate` (Phase 2) originally decided about the
||| *original*, still-Boxed parameter's own dup/drop lifetime -- back
||| when it was read from multiple Boxed-context sites across the loop
||| body -- no longer applies and must be removed outright, not merely
||| left in place: a native C scalar has no refcount header to pass to
||| `idris2rc2_dup`/`idris2rc2_drop`/`idris2rc2_free` in the first
||| place. Safe precisely because every *other* occurrence of the
||| promoted parameter was already redirected to its shadow by the
||| accompanying `renameRCExp` call before this ever runs -- nothing
||| here is deleting a drop some surviving Boxed read still needs.
|||
||| `RCon`'s own field arguments, an `RConCase`/`RConstCase` scrutinee,
||| and `RReuseOffer`'s own `sc`/`dupOnShared` are deliberately *not*
||| touched here (`renameRCExp` still substitutes the id in them, same
||| as everywhere else -- only their *ownership* bookkeeping is a
||| distinct concern from this function's job): a parameter eligible
||| for native shadowing (an `ROp`/`RCmpCase` operand) and a parameter
||| pattern-matched or reuse-checked as a constructor are mutually
||| exclusive at the Idris type level, so a shadowed id is never one of
||| those to begin with; and a shadowed id stored into a constructor
||| field just gets boxed fresh on the spot by `rcVarToBoxedC`,
||| correctly, with no bookkeeping node of its own to strip.
stripOwnership : SortedSet Int -> RCExp -> RCExp
stripOwnership ids (RDup fc v body) =
    let body' = stripOwnership ids body
    in case v of
            RCLoc i => if contains i ids then body' else RDup fc v body'
            _ => RDup fc v body'
stripOwnership ids (RDrop fc vs body) =
    let vs' = filter (\v => case v of RCLoc i => not (contains i ids); _ => True) vs
        body' = stripOwnership ids body
    in if null vs' then body' else RDrop fc vs' body'
stripOwnership ids (RFree fc v body) =
    let body' = stripOwnership ids body
    in case v of
            RCLoc i => if contains i ids then body' else RFree fc v body'
            _ => RFree fc v body'
stripOwnership ids (RLet fc var rep value body) =
    RLet fc var rep (stripOwnership ids value) (stripOwnership ids body)
stripOwnership ids (ROp fc lazy op args postDrop) =
    ROp fc lazy op args (filter (\v => case v of RCLoc i => not (contains i ids); _ => True) postDrop)
stripOwnership ids (RCmpCase fc op args postDrop t f) =
    RCmpCase fc op args (filter (\v => case v of RCLoc i => not (contains i ids); _ => True) postDrop)
      (stripOwnership ids t) (stripOwnership ids f)
stripOwnership ids (RConCase fc sc alts mDef) =
    RConCase fc sc (map (\(MkRConAlt n ci tag as body) => MkRConAlt n ci tag as (stripOwnership ids body)) alts)
      (map (stripOwnership ids) mDef)
stripOwnership ids (RConstCase fc sc alts mDef) =
    RConstCase fc sc (map (\(MkRConstAlt c body) => MkRConstAlt c (stripOwnership ids body)) alts)
      (map (stripOwnership ids) mDef)
stripOwnership ids (RReleaseReuse fc v body) = RReleaseReuse fc v (stripOwnership ids body)
stripOwnership ids (RReuseOffer fc sc dupOnShared body) = RReuseOffer fc sc dupOnShared (stripOwnership ids body)
stripOwnership ids (RLoopContinue fc args) = RLoopContinue fc args
-- RV, RAppName, RUnderApp, RApp, RCon, RExtPrim, RPrimVal, RErased,
-- RCrash: no ownership-tracking positions of their own. RLoop: never
-- actually appears here in practice, same reasoning as
-- `nativeArgTypes`'s own catch-all.
stripOwnership _ e = e

||| Assign consecutive fresh ids, starting at `nextId`, to each eligible
||| `(p, ty)` pair -- pairing each original parameter with its own
||| shadow id and the native type it was found eligible at.
assignShadowIds : (nextId : Int) -> List (Int, PrimType) -> List (Int, Int, PrimType)
assignShadowIds _ [] = []
assignShadowIds nextId ((p, ty) :: rest) = (p, nextId, ty) :: assignShadowIds (nextId + 1) rest

||| Apply self-tail-call loop conversion to one top-level definition,
||| given its own `Name` -- Compiler.RC2.RC doesn't thread a
||| definition's own name through Phase 1/2 at all (nothing there needs
||| it), so this takes it as an explicit argument the same way
||| RC2.idr's `toRCDefs` already has it in hand (paired with the
||| `RCDef` it came from) for every definition. If any self-tail-call is
||| found, wraps the whole (rewritten) body in one `RLoop`: each
||| top-level parameter becomes a loop param reusing its own id,
||| `RBoxed`, unless `nativeArgType` finds it worth promoting to a fresh
||| native shadow (see this module's own header note, and
||| `nativeArgType`/`stripOwnership`'s own doc comments for the
||| eligibility criterion and why the rewrite is safe) -- either way,
||| `initial` always reads the original (always-Boxed) parameter's own
||| value, since that's genuinely where every loop param's value starts
||| from; Compiler.RC2.Emit's `declareLoopParam` does the (skipped, for
||| an unchanged `RBoxed` param -- the common case) unboxing conversion.
|||
||| Fresh shadow ids start one past the highest id already used
||| anywhere in this definition (its own top-level `args`, plus every
||| `RLet`/`RConAlt`-bound id in `body'`, via `collectBoundIds`) -- kept
||| a plain arithmetic maximum rather than a `Core`-threaded counter
||| (like Compiler.RC2.MutualLoop's own `FreshId`) since this whole pass
||| stays a pure function of one definition at a time, no cross-
||| definition state needed.
export
applyLoop : Name -> RCDef -> RCDef
applyLoop self (MkRCFun args retRep body) =
    let argIds = map fst args
        (found, body') = mapTailAppNames (\fc, n, args' => if n == self then Just (RLoopContinue fc args') else Nothing) body
    in MkRCFun args retRep $
         if not found
            then body'
            else
              let nextId : Int
                  nextId = 1 + foldl max (-1) (argIds ++ collectBoundIds body')
                  eligible : List (Int, PrimType)
                  eligible = mapMaybe (\p => map (\ty => (p, ty)) (nativeArgType p body')) argIds
                  shadowed : List (Int, Int, PrimType)
                  shadowed = assignShadowIds nextId eligible
                  renaming : Renaming
                  renaming = fromList $ map (\(p, sid, _) => (p, sid)) shadowed
                  shadowIds : SortedSet Int
                  shadowIds = fromList $ map (\(_, sid, _) => sid) shadowed
                  rewritten : RCExp
                  rewritten = if null shadowed then body' else stripOwnership shadowIds (renameRCExp renaming body')
                  loopParams : List (Int, Rep)
                  loopParams = map (\p => case find (\(p', _, _) => p' == p) shadowed of
                                               Just (_, sid, ty) => (sid, RNative ty)
                                               Nothing => (p, RBoxed)) argIds
              in RLoop emptyFC loopParams (map RCLoc argIds) rewritten
applyLoop _ d = d
