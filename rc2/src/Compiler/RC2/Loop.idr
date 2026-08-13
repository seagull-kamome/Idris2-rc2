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
-- Scope: self-tail-calls only, not mutual recursion between two or
-- more functions (see TODO.md's own framing of this as a distinct,
-- larger piece of future work). A call wrapped in a `LazyReason` is
-- also left alone -- conservatively out of scope, not investigated.
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
  ||| Walk only `e`'s own tail positions -- the exact same set
  ||| Compiler.RC2.Emit's TailPositionStatus threading already visits
  ||| structurally when lowering to C (RLet's body; RDup/RDrop/RFree/
  ||| RReleaseReuse's continuation; RCmpCase's two branches;
  ||| RConCase/RConstCase's alts and default) -- replacing every plain
  ||| (non-lazy), saturated `RAppName` found there whose target is
  ||| `self` with an `RSelfTailCall` carrying the same arguments.
  ||| Anything else (operand positions -- RCon's args, ROp's operands,
  ||| RApp's own callee/arg, ...) is never visited: a self-call sitting
  ||| there isn't in tail position and must keep going through the
  ||| ordinary calling convention. Returns whether any replacement was
  ||| made, alongside the (possibly rewritten) tree.
  export
  convertTailCalls : Name -> RCExp -> (Bool, RCExp)
  convertTailCalls self (RAppName fc Nothing n args) =
      if n == self
         then (True, RSelfTailCall fc args)
         else (False, RAppName fc Nothing n args)
  convertTailCalls self (RLet fc var rep value body) =
      let (found, body') = convertTailCalls self body
      in (found, RLet fc var rep value body')
  convertTailCalls self (RDup fc v cont) =
      let (found, cont') = convertTailCalls self cont
      in (found, RDup fc v cont')
  convertTailCalls self (RDrop fc vs cont) =
      let (found, cont') = convertTailCalls self cont
      in (found, RDrop fc vs cont')
  convertTailCalls self (RFree fc v cont) =
      let (found, cont') = convertTailCalls self cont
      in (found, RFree fc v cont')
  convertTailCalls self (RReleaseReuse fc v cont) =
      let (found, cont') = convertTailCalls self cont
      in (found, RReleaseReuse fc v cont')
  convertTailCalls self (RCmpCase fc op args postDrop t f) =
      let (foundT, t') = convertTailCalls self t
          (foundF, f') = convertTailCalls self f
      in (foundT || foundF, RCmpCase fc op args postDrop t' f')
  convertTailCalls self (RConCase fc sc alts mDef) =
      let altsR = map (convertTailCallsAlt self) alts
          (foundDef, mDef') = convertTailCallsMaybe self mDef
      in (any fst altsR || foundDef, RConCase fc sc (map snd altsR) mDef')
  convertTailCalls self (RConstCase fc sc alts mDef) =
      let altsR = map (convertTailCallsConstAlt self) alts
          (foundDef, mDef') = convertTailCallsMaybe self mDef
      in (any fst altsR || foundDef, RConstCase fc sc (map snd altsR) mDef')
  -- Every other shape (RV, RUnderApp, RApp, RCon, ROp, RExtPrim,
  -- RPrimVal, RErased, RCrash, RSelfTailCall itself, and a *lazy*
  -- RAppName) is either not a tail position at all or already outside
  -- this pass' scope -- left untouched, no replacement.
  convertTailCalls _ e = (False, e)

  convertTailCallsAlt : Name -> RConAlt -> (Bool, RConAlt)
  convertTailCallsAlt self (MkRConAlt name ci tag args body offersReuse) =
      let (found, body') = convertTailCalls self body
      in (found, MkRConAlt name ci tag args body' offersReuse)

  convertTailCallsConstAlt : Name -> RConstAlt -> (Bool, RConstAlt)
  convertTailCallsConstAlt self (MkRConstAlt c body) =
      let (found, body') = convertTailCalls self body
      in (found, MkRConstAlt c body')

  convertTailCallsMaybe : Name -> Maybe RCExp -> (Bool, Maybe RCExp)
  convertTailCallsMaybe self Nothing = (False, Nothing)
  convertTailCallsMaybe self (Just e) =
      let (found, e') = convertTailCalls self e
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
    let (found, body') = convertTailCalls self body
    in MkRCFun args found body'
applyLoop _ d = d
