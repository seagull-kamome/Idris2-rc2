module Compiler.RC2.ConstFold

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Constant folding: constant `ExtPrim` calls (`prim__codegen` --
-- formerly a separate Compiler.RC2.ConstExtPrim pass),
-- arithmetic/comparisons (RPrimVal/RCmpCase), constructors/closures
-- (RCConstCon/RCConstClosure), whole-program CAF-boundary crossing,
-- and RConCase scrutinee resolution. Runs between Compiler.RC2.Inline
-- and Phase 2 annotation. Four distinct designs live in one module --
-- see rc2/doc/const-con-fold.md, const-closure-fold.md,
-- const-caf-fold.md, and cast-fold-scope.md.

import Compiler.RC2.RCExp
import Compiler.RC2.Types

import Core.CompileExpr
import Core.FC
import Core.Primitives
import Core.TT
import Core.Value

import Data.DPair
import Data.List.Quantifiers
import Data.Maybe
import Data.SortedMap
import Data.SortedSet
import Data.Vect

%default covering

||| Cast folding mirrors upstream's own `foldableOp`
||| (idris2-src/src/Compiler/Opts/ConstantFold.idr:20-25) exactly, not
||| `getOp`'s own unguarded Cast dispatch. `IntType` is excluded on
||| either side (backend-dependent width, not provably safe); `Double`
||| is excluded via `intKind` already returning `Nothing` for it
||| (`safeConst` also excludes `Db` outright, belt-and-suspenders).
||| `to = StringType` is its own case, not folded into the generic
||| `intKind from && intKind to` rule, because only the from-integer
||| direction is safe -- `Cast CharType StringType` in particular must
||| stay excluded. See `rc2/doc/cast-fold-scope.md`'s "Char -> String",
||| "Double -> String", and "String as Cast's source" sections for the
||| full investigation of every excluded direction, including why each
||| exclusion can't just be inferred from `intKind`'s current shape.
foldableOp : PrimFn arity -> Bool
foldableOp BelieveMe = False
foldableOp (Cast IntType _) = False
foldableOp (Cast _ IntType) = False
foldableOp (Cast from StringType) = isJust (intKind from)
foldableOp (Cast from to)   = isJust (intKind from) && isJust (intKind to)
foldableOp _                = True

||| Operands ConstFold itself will actually fold -- not `I` (backend-
||| dependent width, same reasoning as `foldableOp`'s `IntType`
||| exclusion) or `Db` (host-eval-vs-runtime-cast mismatch, see
||| `rc2/doc/cast-fold-scope.md`'s "Double -> String"). Exported so
||| `Compiler.RC2.Inline`'s own `allLiteralArgs` guard stays in
||| lockstep with exactly what this pass folds, not a hand-duplicated
||| copy.
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

||| Locals folded to a known constant so far, keyed by `RCLoc`'s own
||| `Int` id -- ids are minted by `RC.idr`'s per-`LiftedDef` `NextVar`
||| counter (monotonic, reset per definition), so no id here can ever
||| be shadowed/reused within the one `RCDef` this is threaded through.
||| Values carry an `IsAnyConstLocal` proof (`Subset`, erased at
||| runtime) so `Env` can only ever hold one of `RCLocal`'s constant
||| forms -- `RCConstCon`/`RCConstClosure` included, see
||| `rc2/doc/const-con-fold.md`/`const-closure-fold.md` -- never a live
||| `RCLoc`.
Env : Type
Env = SortedMap Int (Subset RCLocal IsAnyConstLocal)

||| Resolve `l` against `env` if it's a variable this pass has already
||| folded to a known constant value -- otherwise `l` unchanged (still
||| `RCLoc`, or already one of the other constant forms, which are
||| never looked up).
resolveLocal : Env -> RCLocal -> RCLocal
resolveLocal env l@(RCLoc i) = fromMaybe l (fst <$> lookup i env)
resolveLocal _   l           = l

||| `RCConst` is already a literal (no `RLet` involved, see `bindOne`'s
||| own doc comment in RC.idr); `RCLoc` is resolved against whatever
||| this pass has folded so far. `RCNull`/`RCEmptyCon`/`RCConstCon`
||| never denote a plain `Constant`.
resolveConst : Env -> RCLocal -> Maybe Constant
resolveConst env l = case resolveLocal env l of
                           RCConst c => Just c
                           _         => Nothing

||| `l` is one of `RCLocal`'s constant forms *and* safe to stage as a
||| static C initializer -- kept at full (non-erased) multiplicity so
||| callers can build `allConstLocal`'s own `All` proof. Excludes
||| `RCConst (BI _)`: every other `Constant` renders as a compile-time-
||| constant C expression, but `BI` (GMP's `mpz_t`) always needs a real
||| function call (`idris2rc2_mkIntegerLiteral`). See
||| `rc2/doc/const-con-fold.md`'s Bug #2 for why this exclusion is
||| independent of -- and must be kept alongside -- the `RLet` case's
||| own native-eligibility guard below.
isConstLocalProof : (l : RCLocal) -> Maybe (IsAnyConstLocal l)
isConstLocalProof (RCLoc _)        = Nothing
isConstLocalProof (RCConst (BI _)) = Nothing
isConstLocalProof RCNull                 = Just ItIsNull2
isConstLocalProof (RCConst _)            = Just ItIsConst2
isConstLocalProof (RCEmptyCon {})        = Just ItIsEmptyCon2
isConstLocalProof (RCConstCon {})        = Just ItIsConstCon2
isConstLocalProof (RCConstClosure {})    = Just ItIsConstClosure2

||| Whole-list version of `isConstLocalProof`, collecting each
||| element's own proof into the `All`-shaped obligation `RCConstCon`'s
||| own `argsConst` field requires -- `args` itself stays a plain
||| `List RCLocal` (see RCExp.idr's own doc comment for why
||| `RCConstCon` doesn't need every field re-typed to carry the proof).
allConstLocal : (args : List RCLocal) -> Maybe (All IsAnyConstLocal args)
allConstLocal [] = Just []
allConstLocal (x :: xs) = case isConstLocalProof x of
                               Nothing => Nothing
                               Just p  => map (\ps => p :: ps) (allConstLocal xs)

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

||| 0-arg CAFs already known to fold to a single constant, keyed by
||| `Name` -- a whole-program-scoped companion to `Env` above (which
||| can't name a CAF, only a per-definition local id). Rebuilt each
||| round of `Compiler.RC2.RC2`'s whole-program fixpoint loop. See
||| `rc2/doc/const-caf-fold.md`'s "CAF boundary crossing" for the
||| fixpoint algorithm and its termination argument.
public export
CafTable : Type
CafTable = SortedMap Name (Subset RCLocal IsAnyConstLocal)

findConAlt : Maybe Int -> List RConAlt -> Maybe RConAlt
findConAlt tag [] = Nothing
findConAlt tag (alt@(MkRConAlt _ _ tag' _ _) :: rest) =
    if tag == tag' then Just alt else findConAlt tag rest

insertConArgs : List Int -> List RCLocal -> Env -> Env
insertConArgs (i :: is) (v :: vs) env =
    case isConstLocalProof v of
         Just prf => insertConArgs is vs (insert i (Element v prf) env)
         Nothing  => insertConArgs is vs env
insertConArgs _ _ env = env

||| `Just` the compile-time-known value for an `RExtPrim` call site
||| guaranteed to always evaluate to it, `Nothing` otherwise -- matched
||| by base name only (`NS _ (UN (Basic pn))`), the same shape
||| `Compiler.RC2.Emit`'s own known-ExtPrim whitelist uses (its
||| `emitRC (RExtPrim ...)` case), not a fully-qualified comparison.
||| The `RPrimVal` this produces needs no ownership handling: by the
||| time Phase 2 sees it, it is just another literal (no refcount
||| bookkeeping), like every other constant this module folds.
constExtPrimValue : Name -> List RCLocal -> Maybe Constant
constExtPrimValue (NS _ (UN (Basic "prim__codegen"))) [] = Just (Str "rc2")
constExtPrimValue _ _ = Nothing

-- `foldConst` is self-recursive only (never mutually recursive with a
-- sibling function) -- its two small per-alt helpers are each called
-- from exactly one of its own case clauses, so they live as `where`
-- clauses on those clauses instead of a `mutual` block; each still
-- calls `foldConst` itself directly, which is fine since it's the
-- enclosing definition being defined.
foldConst : CafTable -> Env -> RCExp -> RCExp
-- `value` folds first (recursively, so a nested `RLet` chain like
-- `[1,2,3,4,5]`'s own ANF folds inside-out), then the *fold result*
-- (not the original shape) is classified -- see
-- rc2/doc/const-con-fold.md's Bug #1 for why that distinction matters.
-- A `RPrimVal`/`RCConstCon`/`RCConstClosure` result means "now a known
-- constant": insert into `env`, drop the `RLet` if `body` (post-fold)
-- no longer references the variable.
foldConst caf env (RLet fc var rep value body) =
    let value' = foldConst caf env value
    in case value' of
            -- Only a native-eligible constant (`litRep`) is safe to
            -- splice into `env`/other nodes' `args` in place of the
            -- `RCLoc` -- a non-native-eligible one (`BI`/`Str`) must
            -- keep its real `RCLoc` so `annotate` keeps tracking its
            -- ownership. See rc2/doc/const-con-fold.md's Bug #2: this
            -- guard is what fixes a confirmed `BI` memory leak.
            RPrimVal _ c =>
                case litRep c of
                     Just _ =>
                         let body' = foldConst caf (insert var (Element (RCConst c) ItIsConst2) env) body
                         in if contains (RCLoc var) (freeLocalsR body')
                               then RLet fc var rep value' body'
                               else body'
                     Nothing => RLet fc var rep value' (foldConst caf env body)
            RV _ cval@(RCConstCon {}) =>
                let body' = foldConst caf (insert var (Element cval ItIsConstCon2) env) body
                in if contains (RCLoc var) (freeLocalsR body')
                      then RLet fc var rep value' body'
                      else body'
            -- Mirrors the `RCConstCon` arm above for a `let`-rebinding
            -- of an already-folded closure constant, and also catches
            -- a bare `RUnderApp fc n missing []` used directly as a
            -- `let`'s value (the `RUnderApp` case below already folds
            -- that shape to this same `RV` form first). See
            -- rc2/doc/const-closure-fold.md's "Gap: a let-rebinding of
            -- an already-folded closure didn't propagate".
            RV _ cval@(RCConstClosure {}) =>
                let body' = foldConst caf (insert var (Element cval ItIsConstClosure2) env) body
                in if contains (RCLoc var) (freeLocalsR body')
                      then RLet fc var rep value' body'
                      else body'
            _ => RLet fc var rep value' (foldConst caf env body)
foldConst _ env (RV fc l) = RV fc (resolveLocal env l)
-- A `RCon` whose `args` are all -- directly or via `env` -- already
-- constant folds to `RV` of a single `RCConstCon`. `reuseFrom` is
-- never folded (already excluded by matching only `Nothing`);
-- zero-arity args are excluded too (NIL/NOTHING/ZERO/UNIT already
-- route through `RCNull`, and C has no zero-length static array). See
-- rc2/doc/const-con-fold.md's "Design" for the full reasoning,
-- including the field-by-field partial fold case.
foldConst caf env (RCon fc n ci tag args Nothing) =
    let resolvedArgs = map (resolveLocal env) args
    in case args of
            [] => RCon fc n ci tag args Nothing
            _  => case allConstLocal resolvedArgs of
                       Just argsConst => RV fc (RCConstCon n ci tag resolvedArgs {argsConst})
                       Nothing        => RCon fc n ci tag resolvedArgs Nothing
-- Every other node holding `RCLocal` operands gets them resolved
-- against `env` too, purely so `freeLocalsR` (the `RLet` case above)
-- sees the substitution -- unresolved, a use would keep looking "live"
-- forever, permanently blocking that `RLet` from folding away. See
-- rc2/doc/const-con-fold.md's Bug #1.
--
-- `args = []` is exactly a CAF call: resolve it against `CafTable` the
-- same way a local `RLet`-bound constant resolves against `env`. See
-- rc2/doc/const-caf-fold.md's "CAF boundary crossing".
foldConst caf env (RAppName fc lazy n args) =
    let args' = map (resolveLocal env) args
    in case args' of
            [] => case lookup n caf of
                       Just (Element cval _) => RV fc cval
                       Nothing               => RAppName fc lazy n []
            _  => RAppName fc lazy n args'
-- A literal, zero-args `RUnderApp` denotes the same constant closure
-- value as `RCConstClosure` -- folds unconditionally so a CAF whose
-- whole body is a bare zero-capture closure reference (no `RLet`
-- wrapper) is recognised as constant by `cafValueOf` too. A real
-- capture (`RUnderApp fc n missing (x :: xs)`) falls through
-- unchanged. See rc2/doc/const-closure-fold.md's "Design" section.
foldConst _ env (RUnderApp fc n missing []) = RV fc (RCConstClosure n missing)
foldConst _ env (RUnderApp fc n missing args) = RUnderApp fc n missing (map (resolveLocal env) args)
foldConst _ env (RApp fc lazy c a) = RApp fc lazy (resolveLocal env c) (resolveLocal env a)
foldConst _ env (RExtPrim fc lazy p args postDrop) =
    let args' = map (resolveLocal env) args
    in case constExtPrimValue p args' of
            Just c  => RPrimVal fc c
            Nothing => RExtPrim fc lazy p args' postDrop
foldConst _ env (RStructGet fc structVar sn fn postDrop) =
    RStructGet fc (resolveLocal env structVar) sn fn postDrop
foldConst _ env (RStructSet fc structVar sn fn value postDrop) =
    RStructSet fc (resolveLocal env structVar) sn fn (resolveLocal env value) postDrop
foldConst _ env (ROp fc lazy op args postDrop) =
    let resolvedArgs = map (resolveLocal env) args
    in case resolveConsts env args of
            Just cs => case constFoldOp op cs of
                            Just c  => RPrimVal fc c
                            Nothing => ROp fc lazy op resolvedArgs postDrop
            Nothing => ROp fc lazy op resolvedArgs postDrop
foldConst caf env (RCmpCase fc op args postDrop t f) =
    let t' = foldConst caf env t
        f' = foldConst caf env f
        resolvedArgs = map (resolveLocal env) args
    in case resolveConsts env args of
            Just cs => case constFoldOp op cs of
                            Just (I 1) => t'
                            Just (I 0) => f'
                            _          => RCmpCase fc op resolvedArgs postDrop t' f'
            Nothing => RCmpCase fc op resolvedArgs postDrop t' f'
-- Mirrors `RConstCase`'s own scrutinee-resolution below, for tag
-- dispatch: a resolved `RCConstCon`/`RCEmptyCon` scrutinee makes the
-- whole case disappear in favour of the matching alt (fields
-- re-entered into `env` via `insertConArgs`). See
-- rc2/doc/const-caf-fold.md's "RConCase scrutinee resolution" for the
-- full design, and its "Bugs found" for why `RC.idr`'s `annotate`
-- needed three added intercepts once this could produce a bare `RV`
-- of a non-`RCConstCon`/`RCConstClosure` constant form.
foldConst caf env (RConCase fc sc alts mDef) =
    case resolveLocal env sc of
         RCConstCon _ _ tag args =>
             case findConAlt tag alts of
                  Just (MkRConAlt _ _ _ argIds body) =>
                      foldConst caf (insertConArgs argIds args env) body
                  Nothing =>
                      maybe (RCrash fc "[rc2] ConstFold: RConCase folded scrutinee matched no alt and had no default")
                            (foldConst caf env) mDef
         RCEmptyCon _ _ tag =>
             case findConAlt (Just tag) alts of
                  Just (MkRConAlt _ _ _ _ body) => foldConst caf env body
                  Nothing =>
                      maybe (RCrash fc "[rc2] ConstFold: RConCase folded scrutinee matched no alt and had no default")
                            (foldConst caf env) mDef
         _ => RConCase fc sc (map (foldConstAlt caf env) alts) (map (foldConst caf env) mDef)
  where
    foldConstAlt : CafTable -> Env -> RConAlt -> RConAlt
    foldConstAlt caf env (MkRConAlt name ci tag args body) =
        MkRConAlt name ci tag args (foldConst caf env body)
foldConst caf env (RConstCase fc sc alts mDef) =
    let alts' = map (foldConstConstAlt caf env) alts
        mDef' = map (foldConst caf env) mDef
    in case resolveConst env sc of
            Just c  => fromMaybe (RConstCase fc sc alts' mDef') (findConstAlt c alts' mDef')
            Nothing => RConstCase fc sc alts' mDef'
  where
    foldConstConstAlt : CafTable -> Env -> RConstAlt -> RConstAlt
    foldConstConstAlt caf env (MkRConstAlt c body) = MkRConstAlt c (foldConst caf env body)
foldConst caf env (RDup fc v extra body) = RDup fc v extra (foldConst caf env body)
foldConst caf env (RDrop fc vars body) = RDrop fc vars (foldConst caf env body)
foldConst caf env (RFree fc v body) = RFree fc v (foldConst caf env body)
foldConst caf env (RReleaseReuse fc v body) = RReleaseReuse fc v (foldConst caf env body)
foldConst caf env (RReuseOffer fc sc dupOnShared dropOnUnique body) =
    RReuseOffer fc sc dupOnShared dropOnUnique (foldConst caf env body)
-- `RLoop`/`RAppNameRep` can't exist yet at the point this pass runs
-- (before Compiler.RC2.Loop/DualABI) -- kept total as a plain
-- pass-through rather than assumed unreachable, same reasoning as
-- Loop.idr's `renameRCExp`.
foldConst caf env (RLoop fc loopParams initial prologueDrop body) =
    RLoop fc loopParams initial prologueDrop (foldConst caf env body)
foldConst _ _ e = e

||| A 0-arg CAF whose body has folded to a bare `RV fc cval` -- the
||| shape `Compiler.RC2.RC2`'s own whole-program fixpoint loop looks
||| for after each `foldConstDef` pass to grow `CafTable`. A bare
||| `RPrimVal` body is deliberately not matched: by this point it's
||| already been spliced into every call site by `Compiler.RC2.Inline`'s
||| own `isCallFree`, before `ConstFold` ever runs -- only the
||| `RCConstCon`/`RCConstClosure` shapes `Inline` can't reach still need
||| this route. See `rc2/doc/const-caf-fold.md`'s "Design" for the
||| fixpoint algorithm this feeds.
export
cafValueOf : RCDef -> Maybe (Subset RCLocal IsAnyConstLocal)
cafValueOf (MkRCFun [] _ _ (RV _ cval)) = (\prf => Element cval prf) <$> isConstLocalProof cval
cafValueOf _ = Nothing

export
foldConstDef : CafTable -> RCDef -> RCDef
foldConstDef caf (MkRCFun args retRep isWorker body) = MkRCFun args retRep isWorker (foldConst caf empty body)
foldConstDef caf (MkRCError body) = MkRCError (foldConst caf empty body)
foldConstDef _ d@(MkRCCon _ _ _) = d
foldConstDef _ d@(MkRCForeign _ _ _) = d
