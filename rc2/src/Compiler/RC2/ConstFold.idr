module Compiler.RC2.ConstFold

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Constant folding pass for arithmetic, comparisons, and case-of-constant.
-- Runs between normalization and annotation to simplify the IR after
-- inlining and ExtPrim folding.

import Compiler.RC2.RCExp
import Compiler.RC2.Types

import Core.CompileExpr
import Core.FC
import Core.Primitives
import Core.TT
import Core.Value

import Data.Maybe
import Data.SortedMap
import Data.SortedSet
import Data.Vect

%default covering

||| Cast folding mirrors upstream Compiler.Opts.ConstantFold.foldableOp
||| (idris2-src/src/Compiler/Opts/ConstantFold.idr:20-25) exactly, not
||| just "whatever Core.Primitives.getOp happens to compute" -- getOp's
||| own Cast dispatch (idris2-src/src/Core/Primitives.idr:550-613) has
||| no safety net of its own (it computes Double->Int8 just fine, no
||| Nothing), so the exclusion has to live here. IntType is excluded on
||| either side because its width is backend-dependent, not provably
||| safe; Double is excluded because rc2's own runtime cast for it
||| (support/rc2/numeric.h's idris2rc2_cast_Double_to_*, a raw C cast)
||| is undefined behaviour on out-of-range/NaN/Infinity input, unlike
||| getOp's own Chez-side clamped evaluation -- intKind already returns
||| Nothing for it, so the exclusion is automatic here, not
||| hand-maintained (also, `safeConst` already excludes `Db` from
||| folding entirely, so this is belt-and-suspenders).
|||
||| `to = StringType` is its own case rather than folded into the
||| generic `intKind from && intKind to` rule below, on purpose: only
||| the from-integer direction is safe. `Cast CharType StringType`
||| must stay excluded -- upstream's own `castString` (Primitives.idr:
||| 42) renders a Char via `stripQuotes (show c)`, but `stripQuotes`
||| only strips one character off each end, which is wrong for any
||| `Show Char` output using its own multi-character escape (every
||| codepoint above `\DEL`, plus control characters like `'\n'`):
||| `show '\n'` is `"'\n'"`, so `stripQuotes` yields `"\n"` (backslash,
||| n -- two characters) instead of an actual newline byte. rc2's own
||| `constFoldOp` calls upstream's `getOp` unmodified, so it would
||| inherit that bug verbatim. `intKind CharType = Nothing` keeps this
||| case out of the generic rule too, so excluding it here is doubly
||| covered, not accidentally exposed by widening the rule to `to`.
||| See rc2/doc/cast-fold-scope.md for the full investigation (also
||| covers why the reverse direction, String as Cast's source, stays
||| unfolded regardless of `to`).
foldableOp : PrimFn arity -> Bool
foldableOp BelieveMe = False
foldableOp (Cast IntType _) = False
foldableOp (Cast _ IntType) = False
foldableOp (Cast from StringType) = isJust (intKind from)
foldableOp (Cast from to)   = isJust (intKind from) && isJust (intKind to)
foldableOp _                = True

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

||| Locals this pass has itself folded to a known constant value, keyed
||| by `RCLoc`'s own `Int` id. Ids are minted by `RC.idr`'s per-
||| `LiftedDef` `NextVar` counter (monotonically increasing, reset only
||| at the start of the next `LiftedDef`), so a plain map with no de-
||| Bruijn-style weakening is sufficient -- no id this pass records can
||| ever be shadowed or reused within the one `RCDef` body it's
||| threaded through. Values are `RCLocal` (not just `Constant`) so a
||| folded constant *constructor* (`RCConstCon`, see its own doc
||| comment in RCExp.idr) can be tracked the same way a folded
||| arithmetic result can.
Env : Type
Env = SortedMap Int RCLocal

||| Resolve `l` against `env` if it's a variable this pass has already
||| folded to a known constant value -- otherwise `l` unchanged (still
||| `RCLoc`, or already one of the other constant forms, which are
||| never looked up).
resolveLocal : Env -> RCLocal -> RCLocal
resolveLocal env l@(RCLoc i) = fromMaybe l (lookup i env)
resolveLocal _   l           = l

||| `RCConst` is already a literal (no `RLet` involved, see `bindOne`'s
||| own doc comment in RC.idr); `RCLoc` is resolved against whatever
||| this pass has folded so far. `RCNull`/`RCEmptyCon`/`RCConstCon`
||| never denote a plain `Constant`.
resolveConst : Env -> RCLocal -> Maybe Constant
resolveConst env l = case resolveLocal env l of
                           RCConst c => Just c
                           _         => Nothing

||| `l` is already one of `RCLocal`'s constant forms (not a variable
||| reference) *and* safe to stage as a static C initializer (see
||| `Compiler.RC2.Emit`'s `boxedConstConExpr`) -- used to check whether
||| `resolveLocal` fully resolved a `RCon` field into something an
||| `RCConstCon` can actually hold. Excludes `RCConst (BI _)`: every
||| other `Constant` case renders as either a plain cast/shift macro
||| (`idris2rc2_mkInt8`, etc.) or a reference to an already-staged
||| file-scope static (`Compiler.RC2.Emit`'s `ConstDef`, via
||| `orStagen`), both of which are compile-time constant expressions --
||| but `BI`'s own rendering (`idris2rc2_getSmallInteger`/
||| `idris2rc2_mkIntegerLiteral`) is always a real function call, since
||| GMP's `mpz_t` has no representation a C static initializer can
||| express.
asConstLocal : RCLocal -> Maybe RCLocal
asConstLocal (RCLoc _)        = Nothing
asConstLocal (RCConst (BI _)) = Nothing
asConstLocal l                = Just l

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
  -- `value` is folded first (recursively -- if it's itself a `RLet`
  -- chain building a constant constructor, e.g. a `Cons` cell nesting
  -- another `Cons` cell as its own value, the innermost one folds to a
  -- `RV`-of-`RCConstCon` first, then that fold result is what this
  -- level sees as `value'`), then classified: a `RPrimVal` or a
  -- `RV`-wrapped `RCConstCon` both mean "this variable is now a known
  -- constant" -- insert into `env`, drop the `RLet` entirely if
  -- nothing in `body` (post-fold) still references the variable, same
  -- "moves a value out of `env`-tracking once truly dead" shape either
  -- way, just for constructor values as well as primitive ones now.
  foldConst env (RLet fc var rep value body) =
      let value' = foldConst env value
      in case value' of
              -- Only a native-eligible constant (`litRep` -- see
              -- `asConstLocal`'s own doc comment) is safe to track in
              -- `env` and splice into other nodes' `args` in its place
              -- (the `RAppName`/`ROp`/etc. cases below): a
              -- non-native-eligible one (`BI`, `Str`) is a genuine
              -- heap value RC.idr's `bindOne` deliberately always
              -- keeps behind a real `RCLoc` (see RCExp.idr's module
              -- note) precisely so `Compiler.RC2.RC`'s own `annotate`
              -- tracks its ownership/postDrop normally -- `RCConst`
              -- itself is unconditionally treated as non-Boxed
              -- everywhere in `annotate` (`isBoxedOperand`/
              -- `splitBorrows`/`dropIfLastUse`). Splicing one in
              -- directly would make `annotate` silently skip dropping
              -- a real refcounted value (`idris2rc2_mkIntegerLiteral`,
              -- for `BI`) -- a leak, not just a missed optimisation.
              RPrimVal _ c =>
                  case litRep c of
                       Just _ =>
                           let body' = foldConst (insert var (RCConst c) env) body
                           in if contains (RCLoc var) (freeLocalsR body')
                                 then RLet fc var rep value' body'
                                 else body'
                       Nothing => RLet fc var rep value' (foldConst env body)
              RV _ cval@(RCConstCon {}) =>
                  let body' = foldConst (insert var cval env) body
                  in if contains (RCLoc var) (freeLocalsR body')
                        then RLet fc var rep value' body'
                        else body'
              _ => RLet fc var rep value' (foldConst env body)
  foldConst env (RV fc l) = RV fc (resolveLocal env l)
  -- A `RCon` whose `args` are all -- directly, or via `env` --
  -- already-constant `RCLocal`s folds to a single `RCConstCon` value
  -- (see its own doc comment in RCExp.idr), rendered as a `RV` of that
  -- value so the `RLet` case above can pick it up the same way it
  -- picks up a folded `RPrimVal`. A `reuseFrom` construction is never
  -- folded -- the reuse reservation it's claiming would become
  -- meaningless. Zero-arity `args` are excluded too: NIL/NOTHING/ZERO/
  -- UNIT already take the dedicated `RCNull` route (see `RCon`'s own
  -- `emitRC` case), so a genuinely-zero-arity `RCon` reaching here
  -- would need a zero-length C array in its staged static, which
  -- plain C doesn't allow. Args that don't all resolve stay a `RCon`,
  -- but with each field rewritten to its resolved form -- a constant
  -- field nested inside an otherwise-dynamic construction (e.g.
  -- `Cons x constList`) still gets to reference the staged static
  -- directly rather than re-reading a dead variable.
  foldConst env (RCon fc n ci tag args Nothing) =
      let resolvedArgs = map (resolveLocal env) args
      in case args of
              [] => RCon fc n ci tag args Nothing
              _  => case the (Maybe (List RCLocal)) (traverse asConstLocal resolvedArgs) of
                         Just constArgs => RV fc (RCConstCon n ci tag constArgs)
                         Nothing        => RCon fc n ci tag resolvedArgs Nothing
  -- Every other node holding `RCLocal` operands gets them resolved
  -- against `env` too -- not for a value of its own to fold to (an
  -- `RAppName`/`RApp`/etc. call always still happens), but so a
  -- variable this pass already proved constant is referenced as that
  -- constant directly rather than left as a dead `RCLoc` -- which is
  -- what `freeLocalsR` (the `RLet` case above) uses to decide whether
  -- the `RLet` that built it is now droppable. Left unresolved here,
  -- every such use would keep the variable "live", permanently
  -- defeating the whole pass.
  foldConst env (RAppName fc lazy n args) = RAppName fc lazy n (map (resolveLocal env) args)
  foldConst env (RUnderApp fc n missing args) = RUnderApp fc n missing (map (resolveLocal env) args)
  foldConst env (RApp fc lazy c a) = RApp fc lazy (resolveLocal env c) (resolveLocal env a)
  foldConst env (RExtPrim fc lazy p args) = RExtPrim fc lazy p (map (resolveLocal env) args)
  foldConst env (RStructGet fc structVar sn fn postDrop) =
      RStructGet fc (resolveLocal env structVar) sn fn postDrop
  foldConst env (RStructSet fc structVar sn fn value postDrop) =
      RStructSet fc (resolveLocal env structVar) sn fn (resolveLocal env value) postDrop
  foldConst env (ROp fc lazy op args postDrop) =
      let resolvedArgs = map (resolveLocal env) args
      in case resolveConsts env args of
              Just cs => case constFoldOp op cs of
                              Just c  => RPrimVal fc c
                              Nothing => ROp fc lazy op resolvedArgs postDrop
              Nothing => ROp fc lazy op resolvedArgs postDrop
  foldConst env (RCmpCase fc op args postDrop t f) =
      let t' = foldConst env t
          f' = foldConst env f
          resolvedArgs = map (resolveLocal env) args
      in case resolveConsts env args of
              Just cs => case constFoldOp op cs of
                              Just (I 1) => t'
                              Just (I 0) => f'
                              _          => RCmpCase fc op resolvedArgs postDrop t' f'
              Nothing => RCmpCase fc op resolvedArgs postDrop t' f'
  foldConst env (RConCase fc sc alts mDef) =
      RConCase fc sc (map (foldConstAlt env) alts) (map (foldConst env) mDef)
  foldConst env (RConstCase fc sc alts mDef) =
      let alts' = map (foldConstConstAlt env) alts
          mDef' = map (foldConst env) mDef
      in case resolveConst env sc of
              Just c  => fromMaybe (RConstCase fc sc alts' mDef') (findConstAlt c alts' mDef')
              Nothing => RConstCase fc sc alts' mDef'
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
  foldConst _ e = e

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
