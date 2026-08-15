module Compiler.RC2.ConstFold

-- Constant folding for `ROp` (arithmetic/comparison/string PrimFn
-- application), `RConstCase` (case-of-constant), and `RCmpCase`
-- (Compiler.RC2.RC's own comparison-fused-into-branch node, see its
-- own doc comment in RCExp.idr) -- three shapes that Compiler.RC2.Inline
-- (whole-program Lifted inlining) and Compiler.RC2.ConstExtPrim
-- (folding known-fixed-value ExtPrim calls, e.g. prim__codegen) leave
-- behind once their own folded-in constants end up as PrimFn operands
-- or case scrutinees.
--
-- The actual arithmetic is never reimplemented here: `constFoldOp`
-- below is a thin wrapper around upstream's own `Core.Primitives.getOp`
-- (idris2-src/src/Core/Primitives.idr:566-613), the same function
-- Idris2's own Compiler.Opts.ConstantFold.idr (the direct upstream
-- precedent for this whole pass, operating on `CExp` rather than
-- `RCExp`) uses. `getOp` needs no `Core` monad or global state --
-- purely a `PrimFn arity -> Vect arity (NF vars) -> Maybe (NF vars)`
-- pattern match -- and `NF`'s `NPrimVal : FC -> Constant -> NF vars`
-- constructor holds nothing but an `FC` and a `Constant`, so wrapping/
-- unwrapping it here is exactly as cheap as working with `Constant`
-- directly; `EmptyFC` and `{vars = []}` are throwaway values `getOp`
-- never inspects.
--
-- Folding is deliberately narrower than what `getOp` itself can
-- compute, mirroring (for the arithmetic-safety half) upstream's own
-- `Compiler.Opts.ConstantFold.foldableOp`/`toNF`
-- (idris2-src/src/Compiler/Opts/ConstantFold.idr:20-25, 130-136):
--   * `I` (Int) and `Db` (Double) operands are never folded -- their
--     width/rounding isn't guaranteed to match between this compiler's
--     own host arithmetic and the fixed-width `int64_t`/`double` C
--     rc2 actually generates. Fixed-width ints (`I8`..`I64`,`B8`..`B64`)
--     and arbitrary-precision `BI` have no such mismatch and are safe.
--   * `Cast` is excluded outright (unlike upstream, which admits it for
--     provably-safe fixed-width int pairs via `Core.TT.Primitive`'s own
--     non-exported `intKind`) -- this pass's scope is arithmetic/
--     comparison/string folding, not cast folding, so there's no need
--     to depend on or replicate that non-exported helper.
--   * `BelieveMe` is excluded; `Crash` needs no explicit exclusion
--     since `getOp` itself already falls through to `Nothing` for it.
--
-- Runs as a whole-tree rewrite from Compiler.RC2.RC's `toRCDef`,
-- strictly between Phase 1 (`normalizeDef`) and Phase 2
-- (`annotateDef`) -- same placement and reasoning as
-- Compiler.RC2.ConstExtPrim (see its own module note), and run
-- strictly *after* it so any `RPrimVal` ConstExtPrim itself folds in
-- (e.g. `prim__codegen`'s `"rc2"`) is available to fold further here
-- too (string append onto it, a case branch on it, etc).
--
-- A single top-down pass suffices, no fixpoint iteration: rc2's IR is
-- ANF (a compound sub-expression is never itself an operand -- it's
-- always let-bound to a fresh local first), and `Compiler.RC2.Inline`
-- has already fully finished (at the `Lifted` level, strictly before
-- this pass ever runs) whatever inlining was going to happen. Walking
-- `RLet` outside-in, threading an environment of already-folded
-- locals, sees every chain of dependent constants exactly once.

import Compiler.RC2.RCExp

import Core.CompileExpr
import Core.FC
import Core.Primitives
import Core.TT
import Core.Value

import Data.SortedMap
import Data.SortedSet
import Data.Vect

%default covering

foldableOp : PrimFn arity -> Bool
foldableOp BelieveMe = False
foldableOp (Cast _ _) = False
foldableOp _ = True

||| Operands ConstFold itself will actually fold (i.e. not `I`/`Db`,
||| see `constFoldOp`'s own doc comment for why) -- exported so
||| Compiler.RC2.Inline's own `allLiteralArgs` guard can stay in
||| lockstep with exactly what this pass folds, rather than keeping a
||| second, hand-duplicated copy of this same distinction.
export
safeConst : Constant -> Bool
safeConst (I _) = False
safeConst (Db _) = False
safeConst _ = True

||| Thin wrapper around `Core.Primitives.getOp`: apply `fn` to already-
||| resolved constant operands, subject to the safety exclusions above.
constFoldOp : {0 arity : Nat} -> PrimFn arity -> Vect arity Constant -> Maybe Constant
constFoldOp fn cs =
    if not (foldableOp fn) || not (all safeConst cs)
       then Nothing
       else case getOp {vars = []} fn (map (NPrimVal EmptyFC) cs) of
                 Just (NPrimVal _ c) => Just c
                 _                   => Nothing

||| Locals this pass has itself folded to a known constant, keyed by
||| `RCLoc`'s own `Int` id. Ids are minted by `RC.idr`'s per-`LiftedDef`
||| `NextVar` counter (monotonically increasing, reset only at the
||| start of the next `LiftedDef`), so a plain map with no de-Bruijn-
||| style weakening is sufficient -- no id this pass records can ever
||| be shadowed or reused within the one `RCDef` body it's threaded
||| through.
Env : Type
Env = SortedMap Int Constant

||| `RCConst` is already a literal (no `RLet` involved, see `bindOne`'s
||| own doc comment in RC.idr); `RCLoc` is resolved against whatever
||| this pass has folded so far. `RCNull`/`RCEmptyCon` never denote a
||| `Constant`.
resolveConst : Env -> RCLocal -> Maybe Constant
resolveConst _   (RCConst c) = Just c
resolveConst env (RCLoc i)   = lookup i env
resolveConst _   _           = Nothing

||| Named so `arity` has a type-signature-level home to be inferred
||| from -- inlining this as a bare `traverse (resolveConst env) args`
||| at each call site left `arity` (erased on `ROp`/`RCmpCase`, see
||| RCExp.idr) with nothing but the case scrutinee itself to pin its
||| `Vect` length down, which Idris2's elaborator couldn't resolve.
resolveConsts : {0 arity : Nat} -> Env -> Vect arity RCLocal -> Maybe (Vect arity Constant)
resolveConsts env = traverse (resolveConst env)

findConstAlt : Constant -> List RConstAlt -> Maybe RCExp -> Maybe RCExp
findConstAlt c [] def = def
findConstAlt c (MkRConstAlt c' body :: rest) def =
    if c == c' then Just body else findConstAlt c rest def

mutual
  foldConst : Env -> RCExp -> RCExp
  foldConst _   (RV fc v) = RV fc v
  foldConst _   (RAppName fc lazy n args) = RAppName fc lazy n args
  foldConst _   (RAppNameRep fc n argReps retRep postDrop args) =
      RAppNameRep fc n argReps retRep postDrop args
  foldConst _   (RUnderApp fc n missing args) = RUnderApp fc n missing args
  foldConst _   (RApp fc lazy c a) = RApp fc lazy c a
  foldConst env (RLet fc var rep value body) =
      let value' = foldConst env value
      in case value' of
              RPrimVal _ c =>
                  let body' = foldConst (insert var c env) body
                  in if contains (RCLoc var) (freeLocalsR body')
                        then RLet fc var rep value' body'
                        else body'
              _ => RLet fc var rep value' (foldConst env body)
  foldConst _   (RCon fc n ci tag args reuseFrom) = RCon fc n ci tag args reuseFrom
  foldConst env (ROp fc lazy op args postDrop) =
      case resolveConsts env args of
           Just cs => case constFoldOp op cs of
                           Just c  => RPrimVal fc c
                           Nothing => ROp fc lazy op args postDrop
           Nothing => ROp fc lazy op args postDrop
  foldConst _   (RExtPrim fc lazy p args) = RExtPrim fc lazy p args
  foldConst env (RCmpCase fc op args postDrop t f) =
      let t' = foldConst env t
          f' = foldConst env f
      in case resolveConsts env args of
              Just cs => case constFoldOp op cs of
                              Just (I 1) => t'
                              Just (I 0) => f'
                              _          => RCmpCase fc op args postDrop t' f'
              Nothing => RCmpCase fc op args postDrop t' f'
  foldConst env (RConCase fc sc alts mDef) =
      RConCase fc sc (map (foldConstAlt env) alts) (map (foldConst env) mDef)
  foldConst env (RConstCase fc sc alts mDef) =
      let alts' = map (foldConstConstAlt env) alts
          mDef' = map (foldConst env) mDef
      in case resolveConst env sc of
              Just c  => fromMaybe (RConstCase fc sc alts' mDef') (findConstAlt c alts' mDef')
              Nothing => RConstCase fc sc alts' mDef'
  foldConst _   (RPrimVal fc c) = RPrimVal fc c
  foldConst _   (RErased fc) = RErased fc
  foldConst _   (RCrash fc msg) = RCrash fc msg
  foldConst env (RDup fc v body) = RDup fc v (foldConst env body)
  foldConst env (RDrop fc vars body) = RDrop fc vars (foldConst env body)
  foldConst env (RFree fc v body) = RFree fc v (foldConst env body)
  foldConst env (RReleaseReuse fc v body) = RReleaseReuse fc v (foldConst env body)
  foldConst env (RReuseOffer fc sc dupOnShared body) =
      RReuseOffer fc sc dupOnShared (foldConst env body)
  -- This pass's sole caller (Compiler.RC2.RC's `toRCDef`) only ever
  -- runs it on Phase 1's direct output, before RLoop/RLoopContinue
  -- (Compiler.RC2.Loop, much later) or RAppNameRep (Compiler.RC2.
  -- DualABI, later still) can exist. Kept total (as a plain
  -- pass-through) rather than assumed unreachable, same reasoning as
  -- Loop.idr's own `renameRCExp` and Compiler.RC2.ConstExtPrim for
  -- these same two cases.
  foldConst env (RLoop fc loopParams initial prologueDrop body) =
      RLoop fc loopParams initial prologueDrop (foldConst env body)
  foldConst _   (RLoopContinue fc args postDrop) = RLoopContinue fc args postDrop

  foldConstAlt : Env -> RConAlt -> RConAlt
  foldConstAlt env (MkRConAlt name ci tag args body) =
      MkRConAlt name ci tag args (foldConst env body)

  foldConstConstAlt : Env -> RConstAlt -> RConstAlt
  foldConstConstAlt env (MkRConstAlt c body) = MkRConstAlt c (foldConst env body)

export
foldConstDef : RCDef -> RCDef
foldConstDef (MkRCFun args retRep body) = MkRCFun args retRep (foldConst empty body)
foldConstDef (MkRCError body) = MkRCError (foldConst empty body)
foldConstDef d@(MkRCCon _ _ _) = d
foldConstDef d@(MkRCForeign _ _ _) = d
