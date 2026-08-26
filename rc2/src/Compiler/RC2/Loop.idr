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
  ||| Compiler.RC2.Emit's own `TailPositionStatus` (`Compiler.RC2.EmitUtil`)
  ||| threading already visits when lowering to C -- RLet's body; RDup/RDrop/RFree/
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
  mapTailAppNames f (RReuseOffer fc sc dupOnShared dropOnUnique cont) =
      let (found, cont') = mapTailAppNames f cont
      in (found, RReuseOffer fc sc dupOnShared dropOnUnique cont')
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
  collectBoundIds (RReuseOffer _ _ _ _ body) = collectBoundIds body
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
  renameRCExp ren (RExtPrim fc lazy p args postDrop) =
      RExtPrim fc lazy p (renameLocals ren args) (renameLocals ren postDrop)
  renameRCExp ren (RStructGet fc structVar sn fn postDrop) =
      RStructGet fc (renameLocal ren structVar) sn fn (renameLocals ren postDrop)
  renameRCExp ren (RStructSet fc structVar sn fn value postDrop) =
      RStructSet fc (renameLocal ren structVar) sn fn (renameLocal ren value) (renameLocals ren postDrop)
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
  renameRCExp ren (RReuseOffer fc sc dupOnShared dropOnUnique body) =
      RReuseOffer fc (renameLocal ren sc) (renameLocals ren dupOnShared) (renameLocals ren dropOnUnique) (renameRCExp ren body)
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
||| via `Compiler.RC2.EmitUtil`'s `rcVarToNativeC` rather than
||| `rcVarToBoxedC` (a Boxed-*result*
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
nativeArgTypes p (RReuseOffer _ _ _ _ cont) = nativeArgTypes p cont
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
||| Whether `v` survives `stripOwnership`'s own filtering -- kept
||| (`True`) unless it names one of `ids`; a non-`RCLoc` local (a
||| constant/`NULL`/tagged-empty-con) is never one of `ids` to begin
||| with and always survives.
keepUnlessOwned : SortedSet Int -> RCLocal -> Bool
keepUnlessOwned ids (RCLoc i) = not (contains i ids)
keepUnlessOwned _ _ = True

export
stripOwnership : SortedSet Int -> RCExp -> RCExp
stripOwnership ids (RDup fc v body) =
    let body' = stripOwnership ids body
    in if keepUnlessOwned ids v then RDup fc v body' else body'
stripOwnership ids (RDrop fc vs body) =
    let vs' = filter (keepUnlessOwned ids) vs
        body' = stripOwnership ids body
    in if null vs' then body' else RDrop fc vs' body'
stripOwnership ids (RFree fc v body) =
    let body' = stripOwnership ids body
    in if keepUnlessOwned ids v then RFree fc v body' else body'
stripOwnership ids (RLet fc var rep value body) =
    RLet fc var rep (stripOwnership ids value) (stripOwnership ids body)
stripOwnership ids (ROp fc lazy op args postDrop) =
    ROp fc lazy op args (filter (keepUnlessOwned ids) postDrop)
stripOwnership ids (RCmpCase fc op args postDrop t f) =
    RCmpCase fc op args (filter (keepUnlessOwned ids) postDrop)
      (stripOwnership ids t) (stripOwnership ids f)
stripOwnership ids (RConCase fc sc alts mDef) =
    RConCase fc sc (map (\(MkRConAlt n ci tag as body) => MkRConAlt n ci tag as (stripOwnership ids body)) alts)
      (map (stripOwnership ids) mDef)
stripOwnership ids (RConstCase fc sc alts mDef) =
    RConstCase fc sc (map (\(MkRConstAlt c body) => MkRConstAlt c (stripOwnership ids body)) alts)
      (map (stripOwnership ids) mDef)
stripOwnership ids (RReleaseReuse fc v body) = RReleaseReuse fc v (stripOwnership ids body)
stripOwnership ids (RReuseOffer fc sc dupOnShared dropOnUnique body) = RReuseOffer fc sc dupOnShared dropOnUnique (stripOwnership ids body)
stripOwnership ids (RLoopContinue fc args postDrop) =
    RLoopContinue fc args (filter (keepUnlessOwned ids) postDrop)
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
      (filter (keepUnlessOwned ids) prologueDrop)
      (stripOwnership ids body)
stripOwnership ids (RStructGet fc structVar sn fn postDrop) =
    RStructGet fc structVar sn fn (filter (keepUnlessOwned ids) postDrop)
stripOwnership ids (RStructSet fc structVar sn fn value postDrop) =
    RStructSet fc structVar sn fn value (filter (keepUnlessOwned ids) postDrop)
-- RV, RAppName, RUnderApp, RApp, RCon, RExtPrim, RPrimVal, RErased,
-- RCrash: no ownership-tracking positions of their own.
stripOwnership _ e = e

||| Assign consecutive fresh ids, starting at `nextId`, to each eligible
||| `(p, ty)` pair -- pairing each original parameter with its own
||| shadow id and the native type it was found eligible at.
assignShadowIds : (nextId : Int) -> List (Int, PrimType) -> List (Int, Int, PrimType)
assignShadowIds _ [] = []
assignShadowIds nextId ((p, ty) :: rest) = (p, nextId, ty) :: assignShadowIds (nextId + 1) rest

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
||| `Compiler.RC2.Emit`'s own `TailPositionStatus` (`Compiler.RC2.EmitUtil`)
||| threading already visits (an `RLet`'s own body, `RCmpCase`'s two branches,
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
fillLoopContinuePostDrop loopParams reps (RReuseOffer fc sc dupOnShared dropOnUnique cont) =
    RReuseOffer fc sc dupOnShared dropOnUnique (fillLoopContinuePostDrop loopParams reps cont)
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

||| Every `RLoopContinue` reachable in `e`, collecting each one's own
||| `args` list -- same tree shape `fillLoopContinuePostDrop` itself
||| walks (its own doc comment's "no nested `RLoop`" reasoning applies
||| here unchanged), just collecting instead of rewriting.
collectContinueArgs : RCExp -> List (List RCLocal)
collectContinueArgs (RLet _ _ _ _ body) = collectContinueArgs body
collectContinueArgs (RCmpCase _ _ _ _ t f) = collectContinueArgs t ++ collectContinueArgs f
collectContinueArgs (RConCase _ _ alts mDef) =
    concatMap (\(MkRConAlt _ _ _ _ body) => collectContinueArgs body) alts
      ++ maybe [] collectContinueArgs mDef
collectContinueArgs (RConstCase _ _ alts mDef) =
    concatMap (\(MkRConstAlt _ body) => collectContinueArgs body) alts
      ++ maybe [] collectContinueArgs mDef
collectContinueArgs (RDup _ _ cont) = collectContinueArgs cont
collectContinueArgs (RDrop _ _ cont) = collectContinueArgs cont
collectContinueArgs (RFree _ _ cont) = collectContinueArgs cont
collectContinueArgs (RReleaseReuse _ _ cont) = collectContinueArgs cont
collectContinueArgs (RReuseOffer _ _ _ _ cont) = collectContinueArgs cont
collectContinueArgs (RLoopContinue _ args _) = [args]
collectContinueArgs _ = []

||| Every loop param's own id (a shadow id where native-shadowed, the
||| original top-level parameter id otherwise) that *every* collected
||| `RLoopContinue` supplies completely unchanged (`RCLoc` of that same
||| id, at that same position) -- a param that never actually varies
||| across an iteration, so it has no business being loop-carried at
||| all. See `applyLoop`'s own doc comment for what happens to one of
||| these next.
invariantLoopParamIds : List (Int, Rep) -> List (List RCLocal) -> SortedSet Int
invariantLoopParamIds fullLoopParams continues =
    let start : List (Int, Bool)
        start = map (\(p, _) => (p, True)) fullLoopParams
        settled : List (Int, Bool)
        settled = foldl (\acc, cargs => zipWith (\(p, inv), arg => (p, inv && arg == RCLoc p)) acc cargs)
                         start continues
    in fromList $ map fst $ filter snd settled

||| Drops every `inv`-listed position's own argument from each
||| `RLoopContinue` reachable in `e`, keyed positionally against
||| `fullLoopParams` (the *un*-filtered param list every
||| `RLoopContinue`'s own `args` is still aligned against at this
||| point) -- same tree shape `fillLoopContinuePostDrop` walks.
||| `postDrop` itself is untouched: an invariant position is never a
||| source of one (it's never fed by a fresh Boxed computation -- by
||| definition it's the very same already-native-or-Boxed local every
||| time).
elideInvariantContinueArgs : SortedSet Int -> List (Int, Rep) -> RCExp -> RCExp
elideInvariantContinueArgs inv fullLoopParams (RLet fc var rep value body) =
    RLet fc var rep value (elideInvariantContinueArgs inv fullLoopParams body)
elideInvariantContinueArgs inv fullLoopParams (RCmpCase fc op args postDrop t f) =
    RCmpCase fc op args postDrop
      (elideInvariantContinueArgs inv fullLoopParams t) (elideInvariantContinueArgs inv fullLoopParams f)
elideInvariantContinueArgs inv fullLoopParams (RConCase fc sc alts mDef) =
    RConCase fc sc (map elideAlt alts) (map (elideInvariantContinueArgs inv fullLoopParams) mDef)
  where
    elideAlt : RConAlt -> RConAlt
    elideAlt (MkRConAlt n ci tag as body) = MkRConAlt n ci tag as (elideInvariantContinueArgs inv fullLoopParams body)
elideInvariantContinueArgs inv fullLoopParams (RConstCase fc sc alts mDef) =
    RConstCase fc sc (map (\(MkRConstAlt c body) => MkRConstAlt c (elideInvariantContinueArgs inv fullLoopParams body)) alts)
      (map (elideInvariantContinueArgs inv fullLoopParams) mDef)
elideInvariantContinueArgs inv fullLoopParams (RDup fc v cont) = RDup fc v (elideInvariantContinueArgs inv fullLoopParams cont)
elideInvariantContinueArgs inv fullLoopParams (RDrop fc vs cont) = RDrop fc vs (elideInvariantContinueArgs inv fullLoopParams cont)
elideInvariantContinueArgs inv fullLoopParams (RFree fc v cont) = RFree fc v (elideInvariantContinueArgs inv fullLoopParams cont)
elideInvariantContinueArgs inv fullLoopParams (RReleaseReuse fc v cont) =
    RReleaseReuse fc v (elideInvariantContinueArgs inv fullLoopParams cont)
elideInvariantContinueArgs inv fullLoopParams (RReuseOffer fc sc dupOnShared dropOnUnique cont) =
    RReuseOffer fc sc dupOnShared dropOnUnique (elideInvariantContinueArgs inv fullLoopParams cont)
elideInvariantContinueArgs inv fullLoopParams (RLoopContinue fc args postDrop) =
    RLoopContinue fc (map snd $ filter (\((p, _), _) => not (contains p inv)) (zip fullLoopParams args)) postDrop
elideInvariantContinueArgs _ _ e = e

||| Whether `RCLocal` `v` reads something loop-*variant* (a member of
||| `variant`) -- the single question `isInvariantExpr`'s own operand
||| scan asks of every argument. A constant/`NULL`/tagged-empty-con
||| local is always invariant (it's not an `RCLoc` at all).
noneVariant : SortedSet Int -> RCLocal -> Bool
noneVariant variant (RCLoc i) = not (contains i variant)
noneVariant _ _ = True

||| Whether `e` -- an `RLet`'s own `value`, after peeling the same
||| leading `RDup`/`RDrop`/`RFree`/`RReleaseReuse` wrapper shapes
||| `opNativeUsesThrough` already peels -- is an `ROp`/`RCon` reading
||| only loop-invariant operands (every `RCLocal` argument not a member
||| of `variant`, see `noneVariant`). Both are the *only* two `RCExp`
||| shapes this pass ever hoists (see `hoistInvariantPrefix`'s own doc
||| comment for why nothing else qualifies), and even then only under
||| three further, deliberately conservative exclusions:
|||
||| - `ROp`'s own `lazy` field must be `Nothing` -- a `Just` marks an
|||   operation Idris2 itself decided to keep deferred (`Lazy`/`Inf`);
|||   hoisting would force it unconditionally, ahead of schedule,
|||   changing *when* (or whether) it ever runs -- squarely outside the
|||   "strict evaluation means position doesn't matter" reasoning this
|||   whole pass otherwise relies on.
||| - `RCon`'s own `reuseFrom` must be `Nothing` -- a `Just` ties this
|||   construction to a specific `RReuseOffer`'s own runtime uniqueness
|||   check (`Compiler.RC2.Reuse`), a per-iteration protocol this pass
|||   has no business relocating.
||| - The binding's own declared `Rep` must be `RNative`/`RInlineNative`
|||   -- **not checked by this function itself** (it only looks at
|||   `value`), but by `hoistInvariantPrefix`'s own caller-side guard;
|||   documented here since it's just as essential to this function's
|||   own soundness claim -- see that function's own doc comment for
|||   why a `RBoxed` result is unsound to hoist, confirmed by an actual
|||   `valgrind`-caught double-free the first time this was tried
|||   without the guard.
isInvariantExpr : SortedSet Int -> RCExp -> Bool
isInvariantExpr variant (ROp _ Nothing _ args _) = all (noneVariant variant) (toList args)
isInvariantExpr variant (RCon _ _ _ _ args Nothing) = all (noneVariant variant) args
isInvariantExpr variant (RDup _ _ cont) = isInvariantExpr variant cont
isInvariantExpr variant (RDrop _ _ cont) = isInvariantExpr variant cont
isInvariantExpr variant (RFree _ _ cont) = isInvariantExpr variant cont
isInvariantExpr variant (RReleaseReuse _ _ cont) = isInvariantExpr variant cont
isInvariantExpr _ _ = False

||| Whether `rep` is a native representation (`RNative`/`RInlineNative`)
||| -- see `hoistInvariantPrefix`'s own doc comment for why only these
||| are safe to hoist.
isNativeRep : Rep -> Bool
isNativeRep (RNative _) = True
isNativeRep (RInlineNative _) = True
isNativeRep RBoxed = False

||| Pulls every loop-invariant `RLet` binding out of `e`'s own
||| *unconditional prefix* -- the straight-line chain of `RLet`s
||| (optionally interleaved with non-branching ownership wrappers)
||| reached from `e` before hitting the first branch (`RConCase`/
||| `RConstCase`/`RCmpCase`) or a leaf. Returns the hoisted bindings (in
||| their own original relative order) alongside the rewritten
||| remainder with them removed; everything from the first branch
||| onward -- including a genuinely invariant `ROp`/`RCon` sitting
||| inside just one arm of it -- is left completely untouched (that's
||| `Compiler.RC2.Loop`'s own *single-branch case hoisting*/`RCmpCase`
||| gap, still tracked in `TODO.md`, deliberately not attempted here).
|||
||| **Why "unconditional prefix only" is the right -- and sufficient --
||| scope**: everything in this prefix already runs on *every* pass
||| through `loop:;`, including the very first one (the label sits at
||| the very top of the function's own repeating region, before any
||| exit check). So an expression here is already guaranteed to execute
||| at least once the moment the function is ever called at all --
||| hoisting it to run once, ahead of the loop, instead of once per
||| iteration, can only *reduce* how many times it runs, never turn a
||| "never reached" execution into a "now reached" one. Something
||| sitting inside just one arm of a branch doesn't have that
||| guarantee -- it might never run at all if the loop exits on its
||| very first check -- which is exactly why that shape stays out of
||| scope here.
|||
||| **Why no extra ownership bookkeeping is needed for the operands
||| being *read***: a hoisted binding's own `postDrop`/leading `RDup`
||| etc. moves with it unchanged. Every one of its operands is, by
||| `isInvariantExpr`'s own definition, either a loop-external value
||| already computed exactly once (a top-level argument, or something
||| this same pass -- or the parameter-elision pass before it --
||| already hoisted) or a constant; reading the *same* such value
||| repeatedly, once per iteration, is only possible in the first place
||| because `Compiler.RC2.RC`'s own `annotate` already arranged a
||| net-zero `dup`-then-drop around each repeated read (an outright
||| *consuming* read could never coexist with the value surviving to
||| the next iteration). Collapsing N such net-zero cycles into one
||| doesn't change the net effect on that operand's own refcount at
||| all.
|||
||| **Why only a `Native`/`RInlineNative` *result* is safe to hoist --
||| this part is essential, confirmed the hard way**: the reasoning
||| above is only about the operands being *read*; it says nothing
||| about the hoisted binding's own *result*, `var` itself. A `RBoxed`
||| result has its own, separate liveness story *inside the loop body*
||| that this pass's "unconditional prefix" scan never looks past: if
||| `var` is a fresh Boxed construction only actually *used* on one arm
||| of the branch immediately following the prefix (e.g. only in the
||| loop's own exit value, never on the `continue`-taking arm),
||| `Compiler.RC2.RC`'s own `annotate` already placed a `drop [var]` at
||| the top of the *other* arm (the one that doesn't use it -- exactly
||| the "at most one `RDrop` per branch entry" pattern this whole
||| ownership system is built on). That drop sits *past* this pass's
||| own scan boundary (inside a branch, not the prefix), so hoisting
||| `var`'s construction out from under it leaves that drop stale: what
||| used to release a fresh, per-iteration allocation now double-frees
||| the *one*, shared, hoisted value on every iteration that takes the
||| non-using arm. Reproduced directly: hoisting a `Boxed`-`Rep`
||| invariant `RCon` used only in one arm crashed with `malloc():
||| unaligned tcache chunk detected` and a `valgrind`-confirmed
||| double-free the first time this restriction was missing. A native
||| result sidesteps the whole issue structurally -- native values are
||| never dup'd/dropped anywhere, so no branch can ever hold a stale
||| drop for one -- which is why `hoistInvariantPrefix` below gates on
||| `isNativeRep rep`, not just `isInvariantExpr`.
|||
||| `var` itself is deliberately *not* added to `variant` when hoisted
||| -- it's now a loop-external value too, so a later prefix binding
||| that only reads *it* remains eligible for hoisting in the same
||| pass, no fixed-point iteration required.
hoistInvariantPrefix : SortedSet Int -> RCExp -> (List (Int, Rep, RCExp), RCExp)
hoistInvariantPrefix variant (RLet fc var rep value body) =
    if isNativeRep rep && isInvariantExpr variant value
       then let (hoisted, rest) = hoistInvariantPrefix variant body
            in ((var, rep, value) :: hoisted, rest)
       else let (hoisted, rest) = hoistInvariantPrefix (insert var variant) body
            in (hoisted, RLet fc var rep value rest)
hoistInvariantPrefix variant (RDup fc v cont) =
    let (hoisted, rest) = hoistInvariantPrefix variant cont in (hoisted, RDup fc v rest)
hoistInvariantPrefix variant (RDrop fc vs cont) =
    let (hoisted, rest) = hoistInvariantPrefix variant cont in (hoisted, RDrop fc vs rest)
hoistInvariantPrefix variant (RFree fc v cont) =
    let (hoisted, rest) = hoistInvariantPrefix variant cont in (hoisted, RFree fc v rest)
hoistInvariantPrefix variant (RReleaseReuse fc v cont) =
    let (hoisted, rest) = hoistInvariantPrefix variant cont in (hoisted, RReleaseReuse fc v rest)
hoistInvariantPrefix variant (RReuseOffer fc sc dupOnShared dropOnUnique cont) =
    let (hoisted, rest) = hoistInvariantPrefix variant cont in (hoisted, RReuseOffer fc sc dupOnShared dropOnUnique rest)
hoistInvariantPrefix _ e = ([], e)

------------------------------------------------------------------------
-- Reusing a loop-*invariant* parameter's own original Boxed value for
-- a surviving Boxed-context read, instead of always reboxing fresh
-- from its native shadow (see TODO.md's own "Performance: Loop.idr's
-- own loop-carried native shadow still reboxes fresh on a Boxed-context
-- read" entry, and `rc2/doc/con-alt-native.md`'s own "Reusing the
-- original Boxed field for surviving Boxed-context reads" section for
-- the sibling fix this one is modelled on for
-- `Compiler.RC2.ConAltNative`'s own destructured-field caching).
--
-- Deliberately *not* the same ownership rule as ConAltNative's own
-- `reannotateFieldOwnership` ("first occurrence moves, later ones
-- dup"): an invariant parameter's own Boxed-context read can sit on
-- the loop's own *continue* path, re-executed once per iteration, not
-- just once total the way a destructured field's own alt body is. If
-- the first (textually) iteration's own use *moved* the parameter's
-- only reference, a later iteration's own `dup` of the very same
-- now-freed local would be a use-after-free. Every surviving
-- Boxed-context occurrence is instead unconditionally `dup`'d
-- (`dupInvariantBoxed`), and the parameter's own single release is
-- hoisted to run *once*, after the whole loop has finished evaluating
-- (`applyLoop`'s own `wrapInvariantShadows`, below) -- one dup per
-- occurrence per iteration it's actually reached, one drop total,
-- regardless of iteration count.

||| Mirrors `Compiler.RC2.ConAltNative`'s own `renameOpArgsThrough`
||| exactly (itself mirroring this module's own `opNativeUsesThrough`)
||| -- re-declared here rather than exported across the module boundary,
||| same reasoning as `assignShadowIds` above: once inside the `ROp`
||| that a native-`Rep` `RLet`'s own `value` peels down to (through
||| `RDup`/`RDrop`/`RFree`/`RReleaseReuse`/nested-`RLet`-`body`
||| wrapping), redirect `p`'s own occurrences in that `ROp`'s own
||| `args` to `sid`.
invariantOpArgsThrough : (p : Int) -> (sid : Int) -> RCExp -> RCExp
invariantOpArgsThrough p sid (ROp fc lazy op args postDrop) =
    ROp fc lazy op (map (\a => if a == RCLoc p then RCLoc sid else a) args) postDrop
invariantOpArgsThrough p sid (RDup fc v cont) = RDup fc v (invariantOpArgsThrough p sid cont)
invariantOpArgsThrough p sid (RDrop fc vs cont) = RDrop fc vs (invariantOpArgsThrough p sid cont)
invariantOpArgsThrough p sid (RFree fc v cont) = RFree fc v (invariantOpArgsThrough p sid cont)
invariantOpArgsThrough p sid (RReleaseReuse fc v cont) = RReleaseReuse fc v (invariantOpArgsThrough p sid cont)
invariantOpArgsThrough p sid (RLet fc var rep value body) = RLet fc var rep value (invariantOpArgsThrough p sid body)
invariantOpArgsThrough _ _ e = e

||| Mirrors `nativeArgTypes`'s own walk exactly (identical cases), but
||| rewrites the native-context occurrences it finds instead of
||| collecting their types. Every Boxed-context occurrence of `p` (an
||| `RCon`/`RAppName`/etc. operand -- anywhere `nativeArgTypes` itself
||| falls through to its own `_ = empty` case) is left completely
||| untouched; `dupInvariantBoxed` handles those next.
|||
||| The one addition *not* mirrored from `nativeArgTypes` (which never
||| looks at an `RLoopContinue` at all -- see its own doc comment):
||| `p`'s own occurrence in a continue's own `args`, at the position
||| this parameter still occupies before `elideInvariantContinueArgs`
||| (run later, after this) removes it. That position isn't a
||| native-context read by itself, but `fillLoopContinuePostDrop`
||| (run right after this whole rewrite settles) looks up every
||| continue-arg's own `Rep` by id -- an unrenamed `p` there misses
||| `fullLoopParams`'s own shadow-id-keyed map entirely, reads as
||| `RBoxed` by that lookup's own default, and gets a spurious drop
||| added to *every* continue, once per iteration -- a real,
||| `valgrind`-confirmed double-free/crash caught via
||| `tests/Test19LoopInvariantParam.idr` during development. Redirecting
||| it here, alongside every other occurrence, keeps that lookup
||| correct without needing `fillLoopContinuePostDrop` itself to know
||| anything about invariance.
markInvariantNative : (p : Int) -> (sid : Int) -> RCExp -> RCExp
markInvariantNative p sid (RLet fc var rep value body) =
    let value' = case rep of
                      RNative _ => invariantOpArgsThrough p sid value
                      RInlineNative _ => invariantOpArgsThrough p sid value
                      RBoxed => value
    in RLet fc var rep (markInvariantNative p sid value') (markInvariantNative p sid body)
markInvariantNative p sid (RCmpCase fc op args postDrop t f) =
    RCmpCase fc op (map (\a => if a == RCLoc p then RCLoc sid else a) args) postDrop
             (markInvariantNative p sid t) (markInvariantNative p sid f)
markInvariantNative p sid (RLoopContinue fc args postDrop) =
    RLoopContinue fc (map (\a => if a == RCLoc p then RCLoc sid else a) args) postDrop
markInvariantNative p sid (RDup fc v cont) = RDup fc v (markInvariantNative p sid cont)
markInvariantNative p sid (RDrop fc vs cont) = RDrop fc vs (markInvariantNative p sid cont)
markInvariantNative p sid (RFree fc v cont) = RFree fc v (markInvariantNative p sid cont)
markInvariantNative p sid (RReleaseReuse fc v cont) = RReleaseReuse fc v (markInvariantNative p sid cont)
markInvariantNative p sid (RReuseOffer fc sc dupOnShared dropOnUnique cont) =
    RReuseOffer fc sc dupOnShared dropOnUnique (markInvariantNative p sid cont)
markInvariantNative p sid (RConCase fc sc alts mDef) =
    RConCase fc sc (map (\(MkRConAlt n ci tag as body) => MkRConAlt n ci tag as (markInvariantNative p sid body)) alts)
                    (map (markInvariantNative p sid) mDef)
markInvariantNative p sid (RConstCase fc sc alts mDef) =
    RConstCase fc sc (map (\(MkRConstAlt c body) => MkRConstAlt c (markInvariantNative p sid body)) alts)
                      (map (markInvariantNative p sid) mDef)
markInvariantNative _ _ e = e

||| Whether `p` is referenced anywhere in `e` -- `RCExp.idr`'s own
||| `countUsesR`, specialised to a yes/no question, but with `RLoop`/
||| `RLoopContinue` cases added. `countUsesR` itself was designed for
||| Phase 2 (`RC.idr`'s own `annotate`), which never sees an `RLoop` at
||| all (`Compiler.RC2.Loop` produces its first one strictly after
||| Phase 2 runs) -- its own catch-all `_ = 0` silently undercounts a
||| tree that already contains one, exactly the shape
||| `applyLoop`'s own `wrapInvariantShadows` hands it below (`acc`
||| there is, almost always, the `RLoop` itself, or an `RLet` wrapping
||| one). A real bug caught during development: without these two
||| cases, a Boxed-context read of an invariant parameter sitting
||| *inside* the loop's own body was invisible to this check, and the
||| parameter got dropped immediately instead of kept alive for its own
||| still-live read -- a real, `valgrind`-confirmed crash caught via
||| `tests/Test19LoopInvariantParam.idr`'s own `sumWithBoxedExitOnly`/
||| `sumWithBoxedContinuePath`.
usesInvariant : Int -> RCExp -> Bool
usesInvariant p e = countInvariantUses e > 0
  where
    countInvariantUses : RCExp -> Nat
    countInvariantUses (RV _ v) = if v == RCLoc p then 1 else 0
    countInvariantUses (RAppName _ _ _ args) = length (filter (== RCLoc p) args)
    countInvariantUses (RUnderApp _ _ _ args) = length (filter (== RCLoc p) args)
    countInvariantUses (RApp _ _ c a) = length (filter (== RCLoc p) [c, a])
    countInvariantUses (RLet _ _ _ value body) = countInvariantUses value + countInvariantUses body
    countInvariantUses (RCon _ _ _ _ args _) = length (filter (== RCLoc p) args)
    countInvariantUses (ROp _ _ _ args _) = length (filter (== RCLoc p) (toList args))
    countInvariantUses (RExtPrim _ _ _ args _) = length (filter (== RCLoc p) args)
    countInvariantUses (RStructGet _ structVar _ _ _) = if structVar == RCLoc p then 1 else 0
    countInvariantUses (RStructSet _ structVar _ _ value _) = length (filter (== RCLoc p) [structVar, value])
    countInvariantUses (RCmpCase _ _ args _ t f) =
        length (filter (== RCLoc p) (toList args)) + countInvariantUses t + countInvariantUses f
    countInvariantUses (RConCase _ sc alts mDef) =
        (if sc == RCLoc p then 1 else 0)
        + sum (map (\(MkRConAlt _ _ _ _ body) => countInvariantUses body) alts)
        + maybe 0 countInvariantUses mDef
    countInvariantUses (RConstCase _ sc alts mDef) =
        (if sc == RCLoc p then 1 else 0)
        + sum (map (\(MkRConstAlt _ body) => countInvariantUses body) alts)
        + maybe 0 countInvariantUses mDef
    countInvariantUses (RDup _ v body) = (if v == RCLoc p then 1 else 0) + countInvariantUses body
    countInvariantUses (RDrop _ vars body) = length (filter (== RCLoc p) vars) + countInvariantUses body
    countInvariantUses (RFree _ v body) = (if v == RCLoc p then 1 else 0) + countInvariantUses body
    countInvariantUses (RReleaseReuse _ v body) = (if v == RCLoc p then 1 else 0) + countInvariantUses body
    countInvariantUses (RReuseOffer _ sc dupOnShared dropOnUnique body) =
        (if sc == RCLoc p then 1 else 0) + length (filter (== RCLoc p) dupOnShared)
        + length (filter (== RCLoc p) dropOnUnique) + countInvariantUses body
    countInvariantUses (RLoop _ _ initial prologueDrop body) =
        length (filter (== RCLoc p) initial) + length (filter (== RCLoc p) prologueDrop) + countInvariantUses body
    countInvariantUses (RLoopContinue _ args postDrop) =
        length (filter (== RCLoc p) args) + length (filter (== RCLoc p) postDrop)
    countInvariantUses _ = 0

||| How many `RDup`s an operand list needs for `p`'s own occurrences in
||| it -- unlike `RC.idr`'s own `splitBorrows`, never consults an
||| `owned` state: *every* occurrence gets its own `dup`, unconditionally
||| (see this section's own header note for why -- a loop's own
||| continue path can re-execute the very same occurrence once per
||| iteration, so there's no single "first" occurrence whose own move
||| would ever be safe).
countInvariantDups : (p : Int) -> List RCLocal -> Nat
countInvariantDups p args = length (filter (== RCLoc p) args)

||| Nest `n` `RDup`s for `p` around `e`.
wrapInvariantDups : FC -> Int -> Nat -> RCExp -> RCExp
wrapInvariantDups fc p Z e = e
wrapInvariantDups fc p (S k) e = RDup fc (RCLoc p) (wrapInvariantDups fc p k e)

||| Unconditionally `dup`s every surviving Boxed-context occurrence of
||| `p` in `e` (already known, by construction, to contain no
||| native-context ones -- those were redirected away by
||| `markInvariantNative` before this ever runs). Never touches any
||| other local's own ownership node -- every case below only ever
||| inspects or rewrites `p`'s own occurrences, the same discipline
||| `ConAltNative.idr`'s own `reannotateFieldOwnership` follows (though
||| that function tracks `owned` state to decide move-vs-dup; this one
||| doesn't need to, see this section's own header note).
dupInvariantBoxed : (p : Int) -> RCExp -> RCExp
dupInvariantBoxed p (RV fc v) =
    if v == RCLoc p then RDup fc v (RV fc v) else RV fc v
dupInvariantBoxed p (RAppName fc lazy n args) =
    wrapInvariantDups fc p (countInvariantDups p args) (RAppName fc lazy n args)
dupInvariantBoxed p (RUnderApp fc n missing args) =
    wrapInvariantDups fc p (countInvariantDups p args) (RUnderApp fc n missing args)
dupInvariantBoxed p (RApp fc lazy c a) =
    wrapInvariantDups fc p (countInvariantDups p [c, a]) (RApp fc lazy c a)
dupInvariantBoxed p (RLet fc var rep value body) =
    RLet fc var rep (dupInvariantBoxed p value) (dupInvariantBoxed p body)
dupInvariantBoxed p (RCon fc n ci tag args reuseFrom) =
    wrapInvariantDups fc p (countInvariantDups p args) (RCon fc n ci tag args reuseFrom)
dupInvariantBoxed p (ROp fc lazy op args postDrop) =
    -- Every occurrence needs its own drop once the op is done reading
    -- it, dup'd or not (RC.idr's own `boxedOperands` doesn't consult
    -- ownership either, for the same reason) -- reached only when the
    -- enclosing `RLet`'s own `Rep` is `RBoxed` (a `Native`/`RInlineNative`
    -- one's own `value` was already fully redirected by
    -- `markInvariantNative`, leaving no occurrence of `p` here for this
    -- case to ever see).
    let argsList = toList args
        occ = countInvariantDups p argsList
    in wrapInvariantDups fc p occ (ROp fc lazy op args (postDrop ++ List.replicate occ (RCLoc p)))
-- Mirrors the ROp case immediately above exactly, primitive-agnostic
-- (RC.idr's own annotate RExtPrim case now follows the same contract
-- as ROp's own -- see doc/c-struct-support.md's "Why a dedicated node"
-- section for the fixed-as-of gap this used to be a deliberate no-op
-- for).
dupInvariantBoxed p (RExtPrim fc lazy nm args postDrop) =
    let occ = countInvariantDups p args
    in wrapInvariantDups fc p occ (RExtPrim fc lazy nm args (postDrop ++ List.replicate occ (RCLoc p)))
dupInvariantBoxed p (RStructGet fc structVar sn fn postDrop) =
    wrapInvariantDups fc p (countInvariantDups p [structVar]) (RStructGet fc structVar sn fn postDrop)
dupInvariantBoxed p (RStructSet fc structVar sn fn value postDrop) =
    wrapInvariantDups fc p (countInvariantDups p [structVar, value]) (RStructSet fc structVar sn fn value postDrop)
dupInvariantBoxed p (RCmpCase fc op args postDrop t f) =
    -- markInvariantNative already redirected every native-context
    -- occurrence in `args` to the shadow id -- args is left untouched
    -- here (p genuinely shouldn't still appear in it).
    RCmpCase fc op args postDrop (dupInvariantBoxed p t) (dupInvariantBoxed p f)
dupInvariantBoxed p (RConCase fc sc alts mDef) =
    wrapInvariantDups fc p (countInvariantDups p [sc])
      (RConCase fc sc (map (\(MkRConAlt n ci tag as body) => MkRConAlt n ci tag as (dupInvariantBoxed p body)) alts)
                       (map (dupInvariantBoxed p) mDef))
dupInvariantBoxed p (RConstCase fc sc alts mDef) =
    wrapInvariantDups fc p (countInvariantDups p [sc])
      (RConstCase fc sc (map (\(MkRConstAlt c body) => MkRConstAlt c (dupInvariantBoxed p body)) alts)
                         (map (dupInvariantBoxed p) mDef))
dupInvariantBoxed p (RDup fc v cont) = RDup fc v (dupInvariantBoxed p cont)
dupInvariantBoxed p (RDrop fc vs cont) = RDrop fc vs (dupInvariantBoxed p cont)
dupInvariantBoxed p (RFree fc v cont) = RFree fc v (dupInvariantBoxed p cont)
dupInvariantBoxed p (RReleaseReuse fc v cont) = RReleaseReuse fc v (dupInvariantBoxed p cont)
dupInvariantBoxed p (RReuseOffer fc sc dupOnShared dropOnUnique cont) = RReuseOffer fc sc dupOnShared dropOnUnique (dupInvariantBoxed p cont)
-- `acc` here is `applyLoop`'s own `withHoistedExprs` -- almost always
-- an `RLoop` itself (or an `RLet` chain wrapping one), *not* a tree
-- where one can't appear -- so this case is very much live, unlike the
-- analogous case in `Compiler.RC2.ConAltNative`'s own
-- `reannotateFieldOwnership` (which never sees one, since that pass
-- runs strictly before this one). `p` is never expected to appear in
-- `initial`/`prologueDrop` in practice (an invariant parameter's own
-- continue-arg position is elided by `elideInvariantContinueArgs`,
-- which runs after this, and `initial`/`prologueDrop` are themselves
-- built from `argIds` reads that `markInvariantNative` already
-- redirected to the shadow id wherever `p` itself was invariant) --
-- `wrapInvariantDups` on them is defensive totality, not a load-bearing
-- path.
dupInvariantBoxed p (RLoop fc loopParams initial prologueDrop body) =
    wrapInvariantDups fc p (countInvariantDups p initial + countInvariantDups p prologueDrop)
      (RLoop fc loopParams initial prologueDrop (dupInvariantBoxed p body))
-- Same defensive reasoning as `RLoop` above -- `markInvariantNative`
-- already redirected `p`'s own occurrence in a continue's own `args`
-- to the shadow id, so this case is never expected to actually fire.
dupInvariantBoxed p (RLoopContinue fc args postDrop) =
    wrapInvariantDups fc p (countInvariantDups p args) (RLoopContinue fc args postDrop)
-- RPrimVal/RErased/RCrash carry no locals; RAppNameRep never actually
-- appears here in practice -- this whole pass runs strictly before
-- Compiler.RC2.DualABI ever produces one.
dupInvariantBoxed _ e = e

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
|||
||| A param that turns out loop-*invariant* (`invariantLoopParamIds`:
||| every `RLoopContinue` supplies it completely unchanged) is excluded
||| from `loopParams`/`initial`/every continue's own `args` entirely --
||| it was never going to be reassigned, so it has no business being
||| loop-carried in the IR at all. A Boxed one needs nothing further:
||| its own original id is already, and remains, the enclosing
||| function's own top-level argument (`Compiler.RC2.Emit`'s
||| `declareLoopParam` already special-cases this exact "no
||| declaration needed" shape). A native-shadow-eligible one instead
||| gets hoisted into a one-time `RLet`+`RDrop` pair wrapping the whole
||| loop -- the exact same idiom `Compiler.RC2.ConAltNative`'s own
||| `shadowAltFields` already established for caching a native read of
||| a destructured field, reused here verbatim (see its own doc
||| comment) rather than reinvented.
|||
||| Once `loopParams` is settled, `hoistInvariantPrefix` makes one more
||| pass over the loop's own body, pulling any `ROp`/`RCon` in its
||| unconditional prefix that reads only loop-external operands out to
||| a one-time `RLet` too (see that function's own doc comment for the
||| scope and safety argument) -- nested *inside* the invariant-
||| parameter `RLet`s above, since a hoisted expression may itself read
||| one of those (e.g. a native-shadowed invariant parameter's own
||| shadow id).
export
applyLoop : Name -> RCDef -> RCDef
applyLoop self (MkRCFun args retRep isWorker body) =
    let argIds = map fst args
        (found, body') = mapTailAppNames (\fc, n, args' => if n == self then Just (RLoopContinue fc args' []) else Nothing) body
    in MkRCFun args retRep isWorker $
         if not found
            then body'
            else
              let nextId0 : Int
                  nextId0 = 1 + foldl max (-1) (argIds ++ collectBoundIds body')
                  eligible : List (Int, PrimType)
                  eligible = mapMaybe (\p => map (\ty => (p, ty)) (nativeArgType p body')) argIds
                  -- Decided *before* any renaming touches body' at all
                  -- (see this module's own header note on
                  -- `invariantOpArgsThrough`/`markInvariantNative`/
                  -- `dupInvariantBoxed` above): whether a given continue
                  -- supplies a parameter's own id unchanged is a purely
                  -- structural question, independent of whether that id
                  -- has since been renamed to a shadow -- so this scan
                  -- reaches exactly the same answer run here, on the
                  -- original ids, as `invariantLoopParamIds` used to
                  -- reach running after renaming.
                  invariantIdsPre : SortedSet Int
                  invariantIdsPre = invariantLoopParamIds (map (\p => (p, RBoxed)) argIds) (collectContinueArgs body')
                  eligibleVariant : List (Int, PrimType)
                  eligibleVariant = filter (\(p, _) => not (contains p invariantIdsPre)) eligible
                  eligibleInvariant : List (Int, PrimType)
                  eligibleInvariant = filter (\(p, _) => contains p invariantIdsPre) eligible
                  shadowedVariant : List (Int, Int, PrimType)
                  shadowedVariant = assignShadowIds nextId0 eligibleVariant
                  nextId1 : Int
                  nextId1 = nextId0 + cast (length eligibleVariant)
                  shadowedInvariant : List (Int, Int, PrimType)
                  shadowedInvariant = assignShadowIds nextId1 eligibleInvariant
                  nextId2 : Int
                  nextId2 = nextId1 + cast (length eligibleInvariant)
                  renamingVariant : Renaming
                  renamingVariant = fromList $ map (\(p, sid, _) => (p, sid)) shadowedVariant
                  shadowIdsVariant : SortedSet Int
                  shadowIdsVariant = fromList $ map (\(_, sid, _) => sid) shadowedVariant
                  -- Every eligible *variant* parameter still gets the
                  -- original blanket treatment (every occurrence,
                  -- native and Boxed alike, redirected to the shadow) --
                  -- unchanged, deliberately out of scope (see this
                  -- module's own header note above for why a
                  -- loop-carried shadow's own Boxed-context reuse isn't
                  -- addressed here).
                  variantRewritten : RCExp
                  variantRewritten = if null shadowedVariant then body' else stripOwnership shadowIdsVariant (renameRCExp renamingVariant body')
                  -- Every eligible *invariant* parameter instead only
                  -- has its own native-context occurrences redirected
                  -- (`markInvariantNative`) here -- any surviving
                  -- Boxed-context occurrence is dealt with later, in
                  -- `wrapInvariantShadows` below, once the whole rest of
                  -- this rewrite has settled. `stripOwnership (singleton
                  -- p)` first clears whatever stale ownership
                  -- bookkeeping `annotate` had attached to `p` as an
                  -- ordinary (possibly multiply-used) top-level
                  -- argument -- the same first step
                  -- `Compiler.RC2.ConAltNative`'s own `shadowOneField`
                  -- takes for a destructured field.
                  rewritten : RCExp
                  rewritten = foldr (\(p, sid, _), acc => markInvariantNative p sid (stripOwnership (SortedSet.singleton p) acc))
                                variantRewritten shadowedInvariant
                  fullLoopParams : List (Int, Rep)
                  fullLoopParams = map (\p => case find (\(p', _, _) => p' == p) (shadowedVariant ++ shadowedInvariant) of
                                               Just (_, sid, ty) => (sid, RNative ty)
                                               Nothing => (p, RBoxed)) argIds
                  withPostDrop : RCExp
                  withPostDrop = fillLoopContinuePostDrop fullLoopParams (fromList fullLoopParams) rewritten
                  -- The final loop-param id (shadow id if eligible,
                  -- original id otherwise) for every parameter found
                  -- invariant above -- `invariantLoopParamIds`'s own
                  -- pre-rename result (`invariantIdsPre`), translated
                  -- through `fullLoopParams`'s own id mapping. Includes
                  -- both native-shadow-promoted *and* plain-Boxed
                  -- invariant parameters (the latter need no further
                  -- treatment here -- see `applyLoop`'s own doc comment
                  -- above -- but still need excluding from `loopParams`/
                  -- `initial`/every continue's own `args` exactly like
                  -- before).
                  invariantIds : SortedSet Int
                  invariantIds = fromList $ mapMaybe (\(p, finalId) => if contains p invariantIdsPre then Just finalId else Nothing)
                                   (zip argIds (map fst fullLoopParams))
                  loopParams : List (Int, Rep)
                  loopParams = filter (\(p, _) => not (contains p invariantIds)) fullLoopParams
                  initial : List RCLocal
                  initial = map snd $ filter (\((p, _), _) => not (contains p invariantIds))
                                              (zip fullLoopParams (map RCLoc argIds))
                  finalBody : RCExp
                  finalBody = if null (Prelude.toList invariantIds)
                                 then withPostDrop
                                 else elideInvariantContinueArgs invariantIds fullLoopParams withPostDrop
                  -- Every *still-loop-carried* shadowed param's own
                  -- original top-level arg is dead in its Boxed form
                  -- once its native shadow declaration above runs --
                  -- see `prologueDrop`'s own doc comment on `RLoop` in
                  -- RCExp.idr. An *invariant* shadowed param isn't
                  -- loop-carried any more at all (see
                  -- `wrapInvariantShadows` below) -- its own drop
                  -- happens right there instead, so it's excluded here
                  -- to avoid a double drop.
                  prologueDrop : List RCLocal
                  prologueDrop = mapMaybe (\(p, sid, _) => if contains sid invariantIds then Nothing else Just (RCLoc p))
                                   (shadowedVariant ++ shadowedInvariant)
                  -- Loop-invariant *expression* hoisting (ROp/RCon in
                  -- the loop body's own unconditional prefix, see
                  -- `hoistInvariantPrefix`'s own doc comment): anything
                  -- not a member of the final `loopParams` is, by
                  -- construction, already a loop-external value (a
                  -- plain top-level argument, or something already
                  -- hoisted -- by this pass or the one above), so that
                  -- set alone is the right seed with nothing further to
                  -- compute.
                  hoistResult : (List (Int, Rep, RCExp), RCExp)
                  hoistResult = hoistInvariantPrefix (fromList (map fst loopParams)) finalBody
                  hoistedExprs : List (Int, Rep, RCExp)
                  hoistedExprs = fst hoistResult
                  finalBody2 : RCExp
                  finalBody2 = snd hoistResult
                  innerLoop : RCExp
                  innerLoop = RLoop emptyFC loopParams initial prologueDrop finalBody2
                  withHoistedExprs : RCExp
                  withHoistedExprs = foldr (\(var, rep, value), acc => RLet emptyFC var rep value acc) innerLoop hoistedExprs
                  -- Wrap each native-shadow-promoted invariant parameter
                  -- with its own one-time `RLet`: if no Boxed-context
                  -- occurrence of `p` survived `markInvariantNative`
                  -- above (`countUsesR` finds none), this is the
                  -- original, simpler shape -- an unconditional `RDrop`
                  -- right after the shadow read. Otherwise (see this
                  -- module's own header note above for the full
                  -- reasoning), every surviving occurrence is `dup`'d
                  -- unconditionally (`dupInvariantBoxed`) and `p`'s own
                  -- single release is deferred until the whole rest of
                  -- the loop (`acc`) has finished evaluating -- bound to
                  -- a fresh `resultVar` first (the same
                  -- bind-then-drop-then-return shape `RC.idr`'s own
                  -- `dropDeadLet` uses), threading `nid` onward so a
                  -- second invariant parameter needing this same
                  -- treatment mints its own, later, `resultVar` rather
                  -- than colliding.
                  wrapInvariantShadows : (Int, RCExp)
                  wrapInvariantShadows =
                      foldr wrapOneInvariant (nextId2, withHoistedExprs)
                        (filter (\(_, sid, _) => contains sid invariantIds) shadowedInvariant)
                    where
                      wrapOneInvariant : (Int, Int, PrimType) -> (Int, RCExp) -> (Int, RCExp)
                      wrapOneInvariant (p, sid, ty) (nid, acc) =
                          if not (usesInvariant p acc)
                             then (nid, RLet emptyFC sid (RNative ty) (RV emptyFC (RCLoc p)) (RDrop emptyFC [RCLoc p] acc))
                             else
                               let resultVar = nid
                                   dupped = dupInvariantBoxed p acc
                               in (nid + 1, RLet emptyFC sid (RNative ty) (RV emptyFC (RCLoc p))
                                              (RLet emptyFC resultVar retRep dupped
                                                (RDrop emptyFC [RCLoc p] (RV emptyFC (RCLoc resultVar)))))
              in snd wrapInvariantShadows
applyLoop _ d = d
