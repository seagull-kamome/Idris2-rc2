module Compiler.RC2.Loop

-- Self-tail-call loop conversion: a dedicated pass, mirroring
-- Compiler.RC2.Reuse's own place in the pipeline (runs on the fully
-- Phase-1+2'd, Reuse'd tree, right before Compiler.RC2.Emit -- see
-- RC2.idr's toRCDefs). Where Reuse looks for constructor-reuse
-- opportunities, this pass looks for a function's own self-recursive
-- tail calls and rewrites each one from a generic (closure-build +
-- boxed-trampoline) `RAppName` into an `RSelfTailCall`, which
-- Compiler.RC2.Emit lowers to reassigning the function's own parameter
-- variables and a plain C `goto` back to the top -- no closure
-- allocation, no trampoline dispatch, per iteration.
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
-- Ownership is completely unaffected by this rewrite: Compiler.RC2.RC's
-- `annotate` (Phase 2) already decided the right dup/move behaviour for
-- the `RAppName`'s own arguments before this pass ever runs, exactly as
-- it would for a call to any other function -- converting the call's
-- *shape* doesn't change what should happen to its operands. Any
-- RDup/RDrop/RFree/RReleaseReuse wrapping the `RAppName` is left in
-- place untouched; only the terminal `RAppName` node itself is ever
-- replaced.

import Compiler.RC2.RCExp
import Core.CompileExpr
import Core.FC
import Core.TT

%default covering

mutual
  ||| Rewrite every tail-position, non-lazy `RAppName fc Nothing n args`
  ||| leaf of `e` for which `f fc n args` returns `Just e'`, substituting
  ||| `e'` in its place; every other leaf (including a lazy `RAppName`,
  ||| or one `f` declines by returning `Nothing`) is left untouched.
  ||| "Tail position" here is the exact same structural set
  ||| Compiler.RC2.Emit's TailPositionStatus threading already visits
  ||| when lowering to C -- RLet's body; RDup/RDrop/RFree/
  ||| RReleaseReuse's continuation; RCmpCase's two branches;
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
  -- RPrimVal, RErased, RCrash, RSelfTailCall, and a *lazy* RAppName) is
  -- either not a tail position at all or already outside any tail-
  -- rewrite pass' scope -- left untouched, no replacement.
  mapTailAppNames _ e = (False, e)

  mapTailAppNamesAlt : (FC -> Name -> List RCLocal -> Maybe RCExp) -> RConAlt -> (Bool, RConAlt)
  mapTailAppNamesAlt f (MkRConAlt name ci tag args body offersReuse) =
      let (found, body') = mapTailAppNames f body
      in (found, MkRConAlt name ci tag args body' offersReuse)

  mapTailAppNamesConstAlt : (FC -> Name -> List RCLocal -> Maybe RCExp) -> RConstAlt -> (Bool, RConstAlt)
  mapTailAppNamesConstAlt f (MkRConstAlt c body) =
      let (found, body') = mapTailAppNames f body
      in (found, MkRConstAlt c body')

  mapTailAppNamesMaybe : (FC -> Name -> List RCLocal -> Maybe RCExp) -> Maybe RCExp -> (Bool, Maybe RCExp)
  mapTailAppNamesMaybe f Nothing = (False, Nothing)
  mapTailAppNamesMaybe f (Just e) =
      let (found, e') = mapTailAppNames f e
      in (found, Just e')

||| Apply self-tail-call loop conversion to one top-level definition,
||| given its own `Name` -- Compiler.RC2.RC doesn't thread a
||| definition's own name through Phase 1/2 at all (nothing there needs
||| it), so this takes it as an explicit argument the same way
||| RC2.idr's `toRCDefs` already has it in hand (paired with the
||| `RCDef` it came from) for every definition.
export
applyLoop : Name -> RCDef -> RCDef
applyLoop self (MkRCFun args _ body) =
    let (found, body') = mapTailAppNames (\fc, n, args' => if n == self then Just (RSelfTailCall fc args') else Nothing) body
    in MkRCFun args found body'
applyLoop _ d = d
