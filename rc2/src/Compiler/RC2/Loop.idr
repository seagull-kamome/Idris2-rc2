module Compiler.RC2.Loop

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Self-tail-call loop conversion: wraps self-recursive calls in `RLoop`/`RLoopContinue`
-- to avoid trampoline dispatch, and promotes boxed parameters to native shadows
-- where usage is consistently native.
-- Scope: Self-tail-calls only (mutual recursion handled by MutualLoop).
-- See `rc2/doc/loop-conversion.md` for the full design and rationale.

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
  renameRCExp ren (RLoop fc loopParams initial prologueDrop body) =
      RLoop fc (map (\(i, r) => (renameId ren i, r)) loopParams) (renameLocals ren initial) (renameLocals ren prologueDrop) (renameRCExp ren body)
  renameRCExp ren (RLoopContinue fc args postDrop) = RLoopContinue fc (renameLocals ren args) (renameLocals ren postDrop)
  -- Never actually reached in practice -- Compiler.RC2.DualABI, the
  -- sole producer of RAppNameRep, runs strictly after both this
  -- module and Compiler.RC2.MutualLoop (the only two callers of
  -- renameRCExp) have already finished. Kept total (as a plain
  -- pass-through) rather than assumed unreachable, same reasoning as
  -- this function's own RLoop case just above.
  renameRCExp ren (RAppNameRep fc n argReps retRep postDrop args) =
      RAppNameRep fc n argReps retRep (renameLocals ren postDrop) (renameLocals ren args)

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
||| shared between this op and a later one), *and* through a nested
||| `RLet`'s own `body` (its own `value` is a genuinely separate
||| sub-computation with its own, independently-gated `Rep` -- already
||| covered by `nativeArgTypes`'s own unconditional recursion into it,
||| see below -- but its `body` *is*, transitively, still the same
||| value this outer `ty` governs, e.g. an ANF chain's own last
||| operation sitting in an inner let's `body` rather than being the
||| direct `value` of the outer one: `let v2 : Native Bits64 = let v3 =
||| cast b in xor p v3`, where `xor`'s own read of `p` only becomes
||| visible by walking *into* `v3`'s `body`, still under `v2`'s own
||| already-decided `ty`). Deliberately does **not** invent a `ty` of
||| its own from an unguarded/bare `ROp` with no enclosing `RNative`/
||| `RInlineNative` `RLet` anywhere above it -- `opResultRep`, which
||| `Compiler.RC2.DualABI`'s own `tailValueReps` uses for exactly that
||| shape, would agree with an op's own natural type regardless of
||| whether the *enclosing* context actually renders it natively; a
||| bare tail with no enclosing native `let` genuinely can still render
||| Boxed (`Compiler.RC2.Emit`'s own fallback), and unlike
||| `tailValueReps`'s own use (paired, in lockstep, with
||| `Compiler.RC2.DualABI`'s own return-eligibility decision for the
||| very same op), this function's result is read independently by
||| `Compiler.RC2.Loop`'s own loop-param promotion -- which has no such
||| pairing and runs before any return-eligibility decision exists at
||| all -- so guessing here caused a real, `valgrind`-confirmed leak
||| (`Test9SelfTailLoop`'s own regression the first time this was
||| tried: a loop param's boxed-context read got its ownership bookkeeping
||| stripped on the strength of a bare op's own guessed nativeness, then
||| had to be re-boxed fresh on demand at that Boxed-rendered read, with
||| nothing left to ever drop the fresh box). See `TODO.md`'s git history.
opNativeUsesThrough : (p : Int) -> PrimType -> RCExp -> SortedSet PrimType
opNativeUsesThrough p ty (ROp _ _ op args _) = opNativeUses p ty op args
opNativeUsesThrough p ty (RDup _ _ cont) = opNativeUsesThrough p ty cont
opNativeUsesThrough p ty (RDrop _ _ cont) = opNativeUsesThrough p ty cont
opNativeUsesThrough p ty (RFree _ _ cont) = opNativeUsesThrough p ty cont
opNativeUsesThrough p ty (RReleaseReuse _ _ cont) = opNativeUsesThrough p ty cont
opNativeUsesThrough p ty (RLet _ _ _ _ body) = opNativeUsesThrough p ty body
opNativeUsesThrough _ _ _ = empty

||| Every native `PrimType` at which top-level parameter `p` is read as
||| an operand of a native-result `ROp`, or of a fused `RCmpCase` -- the
||| two, and only two, places Compiler.RC2.Emit ever reads an operand
||| via `rcVarToNativeC` rather than `rcVarToBoxedC` (a Boxed-*result*
||| `ROp`'s own operands are read Boxed too, via `emitRC`'s own ROp
||| case -- only an `RLet`-bound `ROp` whose *own* `Rep` is
||| `RNative`/`RInlineNative` counts here, now including one reached
||| through a chain of nested `RLet`s under that same outer `Rep` --
||| see `opNativeUsesThrough`'s own doc comment). Walks the *whole*
||| tree, not just tail positions -- an operand can appear anywhere. A
||| bare (not-`RLet`-bound) `ROp` -- the tail value of some branch, or a
||| whole one-line function body -- is deliberately *not* treated as a
||| native-context use here, even though its own `opResultRep` could
||| answer the question in isolation: unlike
||| `Compiler.RC2.DualABI`'s own `tailValueReps` (which asks the exact
||| same question about a *return* value, always computed in lockstep
||| with that same op's own eligibility, so the two can never disagree),
||| this function's result is consumed by `Compiler.RC2.Loop`'s own
||| loop-param promotion too, which runs before any function's return
||| eligibility has been decided at all -- a bare tail can, and often
||| does, still render Boxed at that point, and treating it as native
||| anyway strips ownership bookkeeping a since-still-Boxed rendering
||| genuinely needs (confirmed via a real `valgrind`-caught leak in
||| `Test9SelfTailLoop` the first time a bare-`ROp` case was added here
||| unconditionally; see `TODO.md`'s git history).
export
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
-- producer): no native-context operand reads live directly in these
-- (a bare ROp deliberately excepted -- see nativeArgTypes's own doc
-- comment), and none hold a further RCExp to recurse into beyond what
-- RLet/RCmpCase/RConCase/RConstCase above already visit.
nativeArgTypes _ _ = empty

||| The single native `PrimType` top-level parameter `p` should be
||| shadowed at, if `body` reads it that way at all, and consistently
||| (every native-context use agrees on the same type) -- `Nothing` if
||| it's never read natively, or read natively at conflicting types
||| (conservatively left `RBoxed` rather than guessing). Exported for
||| `Compiler.RC2.DualABI`'s own reuse (the same "is this top-level
||| parameter read as a native operand anywhere in the body" question,
||| just asked about a whole function's own parameters rather than only
||| the ones an enclosing `RLoop` carries) -- one definition of this
||| analysis, not two kept in sync by hand.
export
nativeArgType : Int -> RCExp -> Maybe PrimType
nativeArgType p body =
    case Prelude.toList (nativeArgTypes p body) of
         [ty] => Just ty
         _ => Nothing

||| Remove every `RDup`/`RDrop`/`RFree` target, and every `ROp`/
||| `RCmpCase` `postDrop` entry, naming one of `ids`. A native value
||| never needs reference-count bookkeeping at all, so whatever
||| `annotate` (Phase 2) originally decided about one of `ids`'s own
||| dup/drop lifetime -- back when it was Boxed and read from multiple
||| Boxed-context sites -- no longer applies and must be removed
||| outright, not merely left in place: a native C scalar has no
||| refcount header to pass to
||| `idris2rc2_dup`/`idris2rc2_drop`/`idris2rc2_free` in the first
||| place.
|||
||| Safe precisely when every *value-reading* occurrence of each id in
||| `ids` is already consistently native by the time this runs -- two
||| distinct ways that holds, both used in this codebase: this
||| module's own native-shadow promotion (`applyLoop` below) redirects
||| every ordinary read to a *fresh* shadow id first (`renameRCExp`),
||| then calls this with exactly that fresh id set; `Compiler.RC2.DualABI`'s
||| own worker synthesis instead declares an *original* parameter id
||| directly as a native C function parameter in a brand-new function
||| (no id conflict to dodge, since nothing else in that function
||| already used the name) and calls this with that same, unrenamed id.
||| Either way, nothing here is deleting a drop some surviving Boxed
||| read still needs.
|||
||| `RCon`'s own field arguments, an `RConCase`/`RConstCase` scrutinee,
||| and `RReuseOffer`'s own `sc`/`dupOnShared` are deliberately *not*
||| touched here (a renaming caller's own `renameRCExp` still
||| substitutes the id in them, same as everywhere else -- only their
||| *ownership* bookkeeping is a distinct concern from this function's
||| job): an id eligible for a native representation (an `ROp`/
||| `RCmpCase` operand) and one pattern-matched or reuse-checked as a
||| constructor are mutually exclusive at the Idris type level, so a
||| promoted id is never one of those to begin with; and a promoted id
||| stored into a constructor field just gets boxed fresh on the spot
||| by `rcVarToBoxedC`, correctly, with no bookkeeping node of its own
||| to strip. (`Compiler.RC2.ConAltNative`'s own reuse of this function
||| for a destructured field, not just a top-level parameter, never
||| renames *into* an `RReuseOffer`'s own `dupOnShared` either -- it
||| only ever transforms the "core" past every leading
||| `RDup`/`RDrop`/`RFree`/`RReleaseReuse`/`RReuseOffer` wrapper, never
||| the wrappers themselves, precisely so a reuse decision already made
||| there stays completely undisturbed.)
export
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
stripOwnership ids (RLoopContinue fc args postDrop) =
    RLoopContinue fc args (filter (\v => case v of RCLoc i => not (contains i ids); _ => True) postDrop)
-- Unlike every other case in this module, `RLoop` genuinely does show up
-- here: `Compiler.RC2.DualABI`'s own `synthesizeWorker` calls this
-- function over a whole worker body that may already be `RLoop`-wrapped
-- (by this same module's own `applyLoop`, having already run earlier in
-- the pipeline). `loopParams`/`initial` need no filtering of their own
-- (a promoted top-level param's shadow id was already minted fresh by
-- `applyLoop` and never re-promoted itself), but `prologueDrop` must be
-- filtered exactly like an ordinary `RDrop`'s var list above, or a
-- worker whose own signature now renders one of these ids natively
-- would still emit a drop for a value that was never boxed in that
-- worker's own rendering at all.
stripOwnership ids (RLoop fc loopParams initial prologueDrop body) =
    RLoop fc loopParams initial
      (filter (\v => case v of RCLoc i => not (contains i ids); _ => True) prologueDrop)
      (stripOwnership ids body)
-- RV, RAppName, RUnderApp, RApp, RCon, RExtPrim, RPrimVal, RErased,
-- RCrash: no ownership-tracking positions of their own.
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
||| Fills in every `RLoopContinue`'s own `postDrop` -- see `RLoopContinue`'s
||| own doc comment (RCExp.idr) for what this is and why it's needed:
||| every argument that's still `Boxed` at the point it feeds a
||| `Native`/`RInlineNative`-shadowed loop param slot needs an explicit
||| drop once `Compiler.RC2.Emit` reads it natively to build that
||| slot's own next value, the same "no separate statement position to
||| hang an ordinary wrapping drop around a native-context read"
||| reasoning `ROp`/`RCmpCase`/`RAppNameRep`'s own `postDrop` fields
||| already carry.
|||
||| `reps` is threaded through the *same* tail-position shape
||| `Compiler.RC2.Emit`'s own `TailPositionStatus` threading already
||| visits (an `RLet`'s own body, `RCmpCase`'s two branches,
||| `RConCase`/`RConstCase`'s alts and default, every
||| `RDup`/`RDrop`/`RFree`/`RReleaseReuse`/`RReuseOffer`'s own
||| continuation) -- the same shape `Compiler.RC2.DualABI`'s own
||| `applyCallSiteRewriteBody` already threads an analogous `reps` map
||| through, for a closely related reason (deciding whether a call's
||| own argument needs reading natively) -- written fresh here rather
||| than reused, since `Loop.idr` can't import `DualABI.idr` (which
||| itself imports `Loop.idr`, to reuse *this* module's own
||| `nativeArgTypes` -- reusing the other way round would be circular).
||| Seeded from `loopParams` itself (exactly what's in scope at the top
||| of the loop body, positionally paired with the same list this
||| function's own caller already has in hand), extended at every
||| `RLet` (its own declared `Rep`) and every `RConCase`/`RConstCase`
||| alt's own destructured fields (always `RBoxed`, matching every other
||| pass's own treatment of a constructor field's own storage). This
||| pass's own sole caller (`applyLoop` below) never produces a nested
||| `RLoop` within `rewritten` (one function, one `RLoop`, by
||| construction), so there's no case for one here.
fillLoopContinuePostDrop : List (Int, Rep) -> SortedMap Int Rep -> RCExp -> RCExp
fillLoopContinuePostDrop loopParams reps (RLet fc var rep value body) =
    RLet fc var rep value (fillLoopContinuePostDrop loopParams (insert var rep reps) body)
fillLoopContinuePostDrop loopParams reps (RCmpCase fc op args postDrop t f) =
    RCmpCase fc op args postDrop
      (fillLoopContinuePostDrop loopParams reps t) (fillLoopContinuePostDrop loopParams reps f)
fillLoopContinuePostDrop loopParams reps (RConCase fc sc alts mDef) =
    RConCase fc sc (map fillConAlt alts) (map (fillLoopContinuePostDrop loopParams reps) mDef)
  where
    fillConAlt : RConAlt -> RConAlt
    fillConAlt (MkRConAlt n ci tag as body) =
        MkRConAlt n ci tag as (fillLoopContinuePostDrop loopParams (foldl (\m, i => insert i RBoxed m) reps as) body)
fillLoopContinuePostDrop loopParams reps (RConstCase fc sc alts mDef) =
    RConstCase fc sc (map (\(MkRConstAlt c body) => MkRConstAlt c (fillLoopContinuePostDrop loopParams reps body)) alts)
      (map (fillLoopContinuePostDrop loopParams reps) mDef)
fillLoopContinuePostDrop loopParams reps (RDup fc v cont) = RDup fc v (fillLoopContinuePostDrop loopParams reps cont)
fillLoopContinuePostDrop loopParams reps (RDrop fc vs cont) = RDrop fc vs (fillLoopContinuePostDrop loopParams reps cont)
fillLoopContinuePostDrop loopParams reps (RFree fc v cont) = RFree fc v (fillLoopContinuePostDrop loopParams reps cont)
fillLoopContinuePostDrop loopParams reps (RReleaseReuse fc v cont) =
    RReleaseReuse fc v (fillLoopContinuePostDrop loopParams reps cont)
fillLoopContinuePostDrop loopParams reps (RReuseOffer fc sc dupOnShared cont) =
    RReuseOffer fc sc dupOnShared (fillLoopContinuePostDrop loopParams reps cont)
fillLoopContinuePostDrop loopParams reps (RLoopContinue fc args _) =
    let postDrop = mapMaybe (\((_, paramRep), arg) => case paramRep of
                                   RBoxed => Nothing
                                   _ => needsDrop arg) (zip loopParams args)
    in RLoopContinue fc args postDrop
  where
    needsDrop : RCLocal -> Maybe RCLocal
    needsDrop v@(RCLoc i) = case fromMaybe RBoxed (lookup i reps) of
                                  RBoxed => Just v
                                  _ => Nothing
    needsDrop _ = Nothing
fillLoopContinuePostDrop _ _ e = e

export
applyLoop : Name -> RCDef -> RCDef
applyLoop self (MkRCFun args retRep body) =
    let argIds = map fst args
        (found, body') = mapTailAppNames (\fc, n, args' => if n == self then Just (RLoopContinue fc args' []) else Nothing) body
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
                  withPostDrop : RCExp
                  withPostDrop = fillLoopContinuePostDrop loopParams (fromList loopParams) rewritten
                  -- Every shadowed param's own original top-level arg is
                  -- dead in its Boxed form once its native shadow
                  -- declaration above runs -- see `prologueDrop`'s own
                  -- doc comment on `RLoop` in RCExp.idr.
                  prologueDrop : List RCLocal
                  prologueDrop = map (\(p, _, _) => RCLoc p) shadowed
              in RLoop emptyFC loopParams (map RCLoc argIds) prologueDrop withPostDrop
applyLoop _ d = d
