||| Whole-program `Lifted`-to-`Lifted` inlining pass: splices a small,
||| call-free callee's own body directly into its call site, so
||| `Compiler.RC2.RC`'s comparison-fusion analysis (`tryFuseCompare`)
||| can reach a comparison hidden behind an interface method call
||| (e.g. `Ord Int`'s `<=`) the same way it already reaches a bare one.
|||
||| See `rc2/doc/inlining.md` for the full motivation, the two
||| eligibility criteria (only Criterion A -- small, call-free callees
||| -- is implemented; Criterion B was investigated and deliberately
||| not pursued, see its "Eligibility" section), and the "Bugs found
||| and fixed" history -- in particular a leak this pass's own
||| inlining first exposed, that root-caused to two pre-existing,
||| unrelated bugs in `Compiler.RC2.Loop`/`Emit` rather than to this
||| pass's own logic.
module Compiler.RC2.Inline

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Compiler.LambdaLift
import Compiler.RC2.ConstFold

import Core.CompileExpr
import Core.Context
import Core.Core
import Core.FC
import Core.TT

import Data.List
import Data.SortedMap
import Data.Vect

import Libraries.Data.List.SizeOf

%default covering

||| `Vect`'s own stdlib `Traversable` instance doesn't resolve cleanly
||| against `Core`'s own `Applicative` in this codebase (same issue
||| `Compiler.RC2.Emit`'s own identically-named helper already works
||| around) -- a plain hand-written traversal sidesteps it.
traverseVectCore : (a -> Core b) -> Vect n a -> Core (Vect n b)
traverseVectCore f [] = pure []
traverseVectCore f (x :: xs) = do
    x' <- f x
    xs' <- traverseVectCore f xs
    pure (x' :: xs')

------------------------------------------------------------------------
-- IR plumbing: `Weaken`/`Substitutable` for `Lifted`, ported from
-- `Core.TT.Term`'s own `insertNames`/`GenWeaken`/`FreelyEmbeddable`
-- instances and `Core.TT.Term.Subst`'s own `substTerm`. `Lifted`'s own
-- `LLocal` uses the exact same `IsVar`-based representation as `Term`'s
-- own `Local`, so the same generic `Core.TT.Var`/`Core.TT.Subst`
-- combinators (`insertNVarNames`, `find`) apply directly -- no fresh
-- capture-avoidance machinery needed, and no dependency on anything
-- `Lifted`- or rc2-specific. The `LiftedConAlt` cases need one extra
-- `appendAssociative` reshuffle `Term`'s own single-name `Bind` case
-- never needed, since a constructor alt binds a whole *list* of names
-- (`args`) at once -- ported from `Compiler.CaseOpts`'s own
-- `shiftBinderConAlt`, which already solves the identical shape for
-- `CConAlt`.

mutual
  insertNamesLifted : GenWeakenable Lifted
  insertNamesLifted out ns (LLocal fc p)
      = let MkNVar p' = insertNVarNames out ns (MkNVar p) in LLocal fc p'
  insertNamesLifted out ns (LAppName fc lazy n args)
      = LAppName fc lazy n (map (insertNamesLifted out ns) args)
  insertNamesLifted out ns (LUnderApp fc n m args)
      = LUnderApp fc n m (map (insertNamesLifted out ns) args)
  insertNamesLifted out ns (LApp fc lazy c a)
      = LApp fc lazy (insertNamesLifted out ns c) (insertNamesLifted out ns a)
  insertNamesLifted out ns (LLet fc x val sc)
      = LLet fc x (insertNamesLifted out ns val) (insertNamesLifted (suc out) ns sc)
  insertNamesLifted out ns (LCon fc n ci tag args)
      = LCon fc n ci tag (map (insertNamesLifted out ns) args)
  insertNamesLifted out ns (LOp fc lazy op args)
      = LOp fc lazy op (map (insertNamesLifted out ns) args)
  insertNamesLifted out ns (LExtPrim fc lazy p args)
      = LExtPrim fc lazy p (map (insertNamesLifted out ns) args)
  insertNamesLifted out ns (LConCase fc sc alts def)
      = LConCase fc (insertNamesLifted out ns sc)
                    (map (insertNamesConAlt out ns) alts)
                    (map (insertNamesLifted out ns) def)
  insertNamesLifted out ns (LConstCase fc sc alts def)
      = LConstCase fc (insertNamesLifted out ns sc)
                      (map (insertNamesConstAlt out ns) alts)
                      (map (insertNamesLifted out ns) def)
  insertNamesLifted out ns (LPrimVal fc c) = LPrimVal fc c
  insertNamesLifted out ns (LErased fc) = LErased fc
  insertNamesLifted out ns (LCrash fc msg) = LCrash fc msg

  insertNamesConAlt : {0 outer, local, insNs : Scope} -> SizeOf local -> SizeOf insNs ->
                       LiftedConAlt (local ++ outer) -> LiftedConAlt (local ++ (insNs ++ outer))
  insertNamesConAlt out ns (MkLConAlt n ci tag args body)
      = let body' : Lifted ((args ++ local) ++ outer)
                  = rewrite sym (appendAssociative args local outer) in body
        in MkLConAlt n ci tag args $
             rewrite appendAssociative args local (insNs ++ outer)
               in insertNamesLifted (mkSizeOf args + out) ns body'

  insertNamesConstAlt : GenWeakenable LiftedConstAlt
  insertNamesConstAlt out ns (MkLConstAlt c body) = MkLConstAlt c (insertNamesLifted out ns body)

export
GenWeaken Lifted where
  genWeakenNs = insertNamesLifted

export
%hint
WeakenLifted : Weaken Lifted
WeakenLifted = GenWeakenWeakens

export
GenWeaken LiftedConAlt where
  genWeakenNs = insertNamesConAlt

export
%hint
WeakenLiftedConAlt : Weaken LiftedConAlt
WeakenLiftedConAlt = GenWeakenWeakens

export
GenWeaken LiftedConstAlt where
  genWeakenNs = insertNamesConstAlt

export
%hint
WeakenLiftedConstAlt : Weaken LiftedConstAlt
WeakenLiftedConstAlt = GenWeakenWeakens

||| `Lifted`'s own scope index is a purely erased bookkeeping device (every
||| runtime-relevant field -- `idx : Nat` included -- is otherwise
||| unaffected by *appending* extra names on the right, unlike weakening on
||| the left, which genuinely has to shift every `LLocal`'s own `idx`) --
||| so `embed` (append-on-the-right) can use the free, `believe_me`-based
||| default `FreelyEmbeddable` provides for exactly this "nameless
||| representation" situation, same as `Core.TT.Term`'s own instance.
export
FreelyEmbeddable Lifted where
  embed = believe_me

-- Substitution: replace every occurrence of a `dropped` name with the
-- corresponding `vars`-scoped value from `env`, leaving any `outer`
-- (more-recently-bound, i.e. introduced *after* the substitution site)
-- name untouched. Ported from `Core.TT.Term.Subst`'s own `substTerm`;
-- the `LiftedConAlt` case needs the same extra `appendAssociative`
-- reshuffle `insertNamesConAlt` above does, for the same reason.
mutual
  substLifted : Substitutable Lifted Lifted
  substLifted outer dropped env (LLocal fc p)
      = find (\(MkVar p') => LLocal fc p') outer dropped (MkVar p) env
  substLifted outer dropped env (LAppName fc lazy n args)
      = LAppName fc lazy n (map (substLifted outer dropped env) args)
  substLifted outer dropped env (LUnderApp fc n m args)
      = LUnderApp fc n m (map (substLifted outer dropped env) args)
  substLifted outer dropped env (LApp fc lazy c a)
      = LApp fc lazy (substLifted outer dropped env c) (substLifted outer dropped env a)
  substLifted outer dropped env (LLet fc x val sc)
      = LLet fc x (substLifted outer dropped env val) (substLifted (suc outer) dropped env sc)
  substLifted outer dropped env (LCon fc n ci tag args)
      = LCon fc n ci tag (map (substLifted outer dropped env) args)
  substLifted outer dropped env (LOp fc lazy op args)
      = LOp fc lazy op (map (substLifted outer dropped env) args)
  substLifted outer dropped env (LExtPrim fc lazy p args)
      = LExtPrim fc lazy p (map (substLifted outer dropped env) args)
  substLifted outer dropped env (LConCase fc sc alts def)
      = LConCase fc (substLifted outer dropped env sc)
                    (map (substConAlt outer dropped env) alts)
                    (map (substLifted outer dropped env) def)
  substLifted outer dropped env (LConstCase fc sc alts def)
      = LConstCase fc (substLifted outer dropped env sc)
                      (map (substConstAlt outer dropped env) alts)
                      (map (substLifted outer dropped env) def)
  substLifted outer dropped env (LPrimVal fc c) = LPrimVal fc c
  substLifted outer dropped env (LErased fc) = LErased fc
  substLifted outer dropped env (LCrash fc msg) = LCrash fc msg

  substConAlt : {0 outSc, dropSc, vars : Scope} -> SizeOf outSc -> SizeOf dropSc -> Subst Lifted dropSc vars ->
                LiftedConAlt (outSc ++ (dropSc ++ vars)) -> LiftedConAlt (outSc ++ vars)
  substConAlt outer dropped env (MkLConAlt n ci tag args body)
      = let body' : Lifted ((args ++ outSc) ++ (dropSc ++ vars))
                  = rewrite sym (appendAssociative args outSc (dropSc ++ vars)) in body
        in MkLConAlt n ci tag args $
             rewrite appendAssociative args outSc vars
               in substLifted (mkSizeOf args + outer) dropped env body'

  substConstAlt : Substitutable Lifted LiftedConstAlt
  substConstAlt outer dropped env (MkLConstAlt c body) = MkLConstAlt c (substLifted outer dropped env body)

||| Builds the positional substitution environment for a call, matching
||| `calleeArgs`'s own order one-for-one against the call's own argument
||| list -- `Core`-level failure (never expected to actually trigger: a
||| fully-saturated `LAppName` call's own arity always matches its
||| target's declared arity) rather than a partial function, so a future
||| change elsewhere that broke this invariant would fail loudly instead
||| of silently miscompiling.
toSubst : {0 vars : Scope} -> (calleeArgs : Scope) -> List (Lifted vars) -> Core (Subst Lifted calleeArgs vars)
toSubst [] [] = pure []
toSubst (_ :: ds) (a :: as) = (a ::) <$> toSubst ds as
toSubst _ _ = throw (InternalError "[rc2] Compiler.RC2.Inline: call arity mismatch")

||| `calleeArgs` is erased in `inlineCall`'s own context (see
||| `FreelyEmbeddable Lifted`'s own note -- `Lifted`'s scope index carries
||| no runtime information at all), so its own length can't be counted
||| via `mkSizeOf calleeArgs` directly; `env`'s own cons-spine already
||| encodes that length as genuine runtime data, so read it from there
||| instead.
sizeOfSubst : Subst tm ds vars -> SizeOf ds
sizeOfSubst [] = zero
sizeOfSubst (_ :: rest) = suc (sizeOfSubst rest)

||| Splices a closed callee's own body (referencing only its own
||| `calleeArgs`, since only a genuine top-level definition -- `scope =
||| []` -- is ever considered eligible, see `buildEligible`) into a call
||| site, substituting each argument reference with the corresponding
||| caller-side expression in `env`. `embed` first widens `body`'s own
||| closed scope to include the caller's own `vars` (free, since
||| `Lifted`'s own scope index is nameless at runtime -- see
||| `FreelyEmbeddable Lifted` above), then `substLifted` (with an empty
||| `outer`) replaces every one of `calleeArgs`'s own occurrences.
inlineCall : {0 calleeArgs, vars : Scope} -> Lifted calleeArgs -> Subst Lifted calleeArgs vars -> Lifted vars
inlineCall body env = substLifted zero (sizeOfSubst env) env (embed body)

------------------------------------------------------------------------
-- Case-of-case collapse, ported from upstream `Compiler.CaseOpts`'s own
-- `doCaseOfCase`/`doCaseOfConstCase`/`tryCaseOfCase`/`caseOfCase`
-- (`CExp`-level) onto `Lifted` -- needed because plain substitution
-- alone, spliced into a scrutinee position, produces a "case of case"
-- shape (`case (case x of ...) of ...`) that `Compiler.RC2.RC`'s own
-- `tryFuseCompare` doesn't recognise; collapsing it back into a single
-- case over `x` (duplicating the outer case into every inner branch) is
-- what lets fusion actually fire. `Lifted` has no `LLam` (lambda-lifting
-- already eliminated every lambda), so upstream's own "lift out lambda"
-- half of `CaseOpts` (`caseLam`) has no counterpart here at all -- only
-- the case-of-case half is ported.

doCaseOfCase : FC -> (x : Lifted vars) -> (xalts : List (LiftedConAlt vars)) -> (xdef : Maybe (Lifted vars)) ->
               (alts : List (LiftedConAlt vars)) -> (def : Maybe (Lifted vars)) -> Lifted vars
doCaseOfCase fc x xalts xdef alts def
    = LConCase fc x (map updateAlt xalts) (map updateDef xdef)
  where
    updateAlt : LiftedConAlt vars -> LiftedConAlt vars
    updateAlt (MkLConAlt n ci t args sc)
        = MkLConAlt n ci t args $
              LConCase fc sc (map (weakenNs (mkSizeOf args)) alts) (map (weakenNs (mkSizeOf args)) def)
    updateDef : Lifted vars -> Lifted vars
    updateDef sc = LConCase fc sc alts def

doCaseOfConstCase : FC -> (x : Lifted vars) -> (xalts : List (LiftedConstAlt vars)) -> (xdef : Maybe (Lifted vars)) ->
                     (alts : List (LiftedConstAlt vars)) -> (def : Maybe (Lifted vars)) -> Lifted vars
doCaseOfConstCase fc x xalts xdef alts def
    = LConstCase fc x (map updateAlt xalts) (map updateDef xdef)
  where
    updateAlt : LiftedConstAlt vars -> LiftedConstAlt vars
    updateAlt (MkLConstAlt c sc) = MkLConstAlt c $ LConstCase fc sc alts def
    updateDef : Lifted vars -> Lifted vars
    updateDef sc = LConstCase fc sc alts def

||| To minimise the risk of code-size blowup from duplicating the outer
||| case into every inner branch, only collapse when the inner case's own
||| alternatives are all constructor-headed (or there's only one, with no
||| default) -- identical restriction to upstream's own `canCaseOfCase`.
tryCaseOfCase : Lifted vars -> Maybe (Lifted vars)
tryCaseOfCase (LConCase fc (LConCase fc' x xalts xdef) alts def)
    = if canCaseOfCase xalts xdef then Just (doCaseOfCase fc' x xalts xdef alts def) else Nothing
  where
    isCon : Lifted vars -> Bool
    isCon (LCon {}) = True
    isCon _ = False
    conCase : LiftedConAlt vars -> Bool
    conCase (MkLConAlt _ _ _ _ (LCon {})) = True
    conCase _ = False
    canCaseOfCase : List (LiftedConAlt vars) -> Maybe (Lifted vars) -> Bool
    canCaseOfCase [] _ = True
    canCaseOfCase [_] Nothing = True
    canCaseOfCase xs mdef = all conCase xs && maybe True isCon mdef
tryCaseOfCase (LConstCase fc (LConstCase fc' x xalts xdef) alts def)
    = if canCaseOfCase xalts xdef then Just (doCaseOfConstCase fc' x xalts xdef alts def) else Nothing
  where
    isConst : Lifted vars -> Bool
    isConst (LPrimVal {}) = True
    isConst _ = False
    constCase : LiftedConstAlt vars -> Bool
    constCase (MkLConstAlt _ (LPrimVal {})) = True
    constCase _ = False
    canCaseOfCase : List (LiftedConstAlt vars) -> Maybe (Lifted vars) -> Bool
    canCaseOfCase [] _ = True
    canCaseOfCase [_] Nothing = True
    canCaseOfCase xs mdef = all constCase xs && maybe True isConst mdef
tryCaseOfCase _ = Nothing

||| Collapse a single node, retrying up to a small, fixed depth (matching
||| upstream's own `caseOfCase`) -- a chain of more than a handful of
||| nested case-of-case shapes at one spot is not a pattern this pass's
||| own inlining is expected to ever actually produce.
caseOfCaseHere : Lifted vars -> Lifted vars
caseOfCaseHere tm = go 5 tm
  where
    go : Nat -> Lifted vars -> Lifted vars
    go Z tm = tm
    go (S k) tm = maybe tm (go k) (tryCaseOfCase tm)

-- Applies `caseOfCaseHere` throughout the whole tree, bottom-up (a
-- node's own children are collapsed first, so the collapse check at
-- this node sees its scrutinee already in its own final, smallest
-- form).
mutual
  collapseCaseOfCase : Lifted vars -> Lifted vars
  collapseCaseOfCase (LAppName fc lazy n args) = LAppName fc lazy n (map collapseCaseOfCase args)
  collapseCaseOfCase (LUnderApp fc n m args) = LUnderApp fc n m (map collapseCaseOfCase args)
  collapseCaseOfCase (LApp fc lazy c a) = LApp fc lazy (collapseCaseOfCase c) (collapseCaseOfCase a)
  collapseCaseOfCase (LLet fc x val sc) = LLet fc x (collapseCaseOfCase val) (collapseCaseOfCase sc)
  collapseCaseOfCase (LCon fc n ci tag args) = LCon fc n ci tag (map collapseCaseOfCase args)
  collapseCaseOfCase (LOp fc lazy op args) = LOp fc lazy op (map collapseCaseOfCase args)
  collapseCaseOfCase (LExtPrim fc lazy p args) = LExtPrim fc lazy p (map collapseCaseOfCase args)
  collapseCaseOfCase (LConCase fc sc alts def)
      = caseOfCaseHere $ LConCase fc (collapseCaseOfCase sc) (map collapseConAlt alts) (map collapseCaseOfCase def)
  collapseCaseOfCase (LConstCase fc sc alts def)
      = caseOfCaseHere $ LConstCase fc (collapseCaseOfCase sc) (map collapseConstAlt alts) (map collapseCaseOfCase def)
  collapseCaseOfCase e = e

  collapseConAlt : LiftedConAlt vars -> LiftedConAlt vars
  collapseConAlt (MkLConAlt n ci t args sc) = MkLConAlt n ci t args (collapseCaseOfCase sc)

  collapseConstAlt : LiftedConstAlt vars -> LiftedConstAlt vars
  collapseConstAlt (MkLConstAlt c sc) = MkLConstAlt c (collapseCaseOfCase sc)

------------------------------------------------------------------------
-- Eligibility (Criterion A: small, call-free body)

||| A cheap, coarse structural node count -- not calibrated against
||| actual generated-C size, just a proxy for "small helper" to bound how
||| much code a single inlining decision can duplicate across call sites.
sizeOf : Lifted vars -> Nat
sizeOfConAlt : LiftedConAlt vars -> Nat
sizeOfConstAlt : LiftedConstAlt vars -> Nat

sizeOf (LLocal _ _) = 1
sizeOf (LAppName _ _ _ args) = 1 + sum (map sizeOf args)
sizeOf (LUnderApp _ _ _ args) = 1 + sum (map sizeOf args)
sizeOf (LApp _ _ c a) = 1 + sizeOf c + sizeOf a
sizeOf (LLet _ _ val sc) = 1 + sizeOf val + sizeOf sc
sizeOf (LCon _ _ _ _ args) = 1 + sum (map sizeOf args)
sizeOf (LOp _ _ _ args) = 1 + sum (toList (map sizeOf args))
sizeOf (LExtPrim _ _ _ args) = 1 + sum (map sizeOf args)
sizeOf (LConCase _ sc alts def) = 1 + sizeOf sc + sum (map sizeOfConAlt alts) + maybe 0 sizeOf def
sizeOf (LConstCase _ sc alts def) = 1 + sizeOf sc + sum (map sizeOfConstAlt alts) + maybe 0 sizeOf def
sizeOf (LPrimVal _ _) = 1
sizeOf (LErased _) = 1
sizeOf (LCrash _ _) = 1

sizeOfConAlt (MkLConAlt _ _ _ _ sc) = sizeOf sc
sizeOfConstAlt (MkLConstAlt _ sc) = sizeOf sc

smallBodyThreshold : Nat
smallBodyThreshold = 24

||| True if `e` contains no function invocation of any kind -- Criterion
||| A's own defining requirement: such a callee can never itself contain
||| a further call to inline, so splicing it in never needs a second
||| inlining pass over the result (see `inlineLifted`'s own module note).
isCallFree : Lifted vars -> Bool
isCallFreeConAlt : LiftedConAlt vars -> Bool
isCallFreeConstAlt : LiftedConstAlt vars -> Bool

isCallFree (LLocal _ _) = True
isCallFree (LAppName {}) = False
isCallFree (LUnderApp {}) = False
isCallFree (LApp {}) = False
isCallFree (LExtPrim {}) = False
isCallFree (LLet _ _ val sc) = isCallFree val && isCallFree sc
isCallFree (LCon _ _ _ _ args) = all isCallFree args
isCallFree (LOp _ _ _ args) = all isCallFree (toList args)
isCallFree (LConCase _ sc alts def) = isCallFree sc && all isCallFreeConAlt alts && maybe True isCallFree def
isCallFree (LConstCase _ sc alts def) = isCallFree sc && all isCallFreeConstAlt alts && maybe True isCallFree def
isCallFree (LPrimVal _ _) = True
isCallFree (LErased _) = True
isCallFree (LCrash _ _) = True

isCallFreeConAlt (MkLConAlt _ _ _ _ sc) = isCallFree sc
isCallFreeConstAlt (MkLConstAlt _ sc) = isCallFree sc

||| A Criterion-A-eligible callee: its own parameter names, in order, and
||| its own body -- necessarily closed over exactly those names (only a
||| definition with an empty `scope`, i.e. a genuine top-level definition
||| rather than a lifted-out closure helper, is ever considered, see
||| `buildEligible`), so `eligBody`'s own type can reference `eligArgs`
||| directly with no further embedding needed at this stage.
record Eligible where
  constructor MkEligible
  eligArgs : List Name
  eligBody : Lifted eligArgs

buildEligible : List (Name, LiftedDef) -> SortedMap Name Eligible
buildEligible lds = SortedMap.fromList $ mapMaybe toEntry lds
  where
    toEntry : (Name, LiftedDef) -> Maybe (Name, Eligible)
    toEntry (n, MkLFun args [] body)
        = if isCallFree body && sizeOf body <= smallBodyThreshold
             then Just (n, MkEligible args body)
             else Nothing
    toEntry _ = Nothing

isPrimVal : Lifted vars -> Bool
isPrimVal (LPrimVal _ _) = True
isPrimVal _ = False

||| Never inline a call whose arguments are all bare literal constants
||| *and* include at least one Compiler.RC2.ConstFold itself won't fold
||| away (an `I`/`Db` literal -- see its own `safeConst`, reused here
||| so this stays in lockstep with exactly what it folds): gcc's own
||| `-Werror=overflow` can statically prove an intentional fixed-width
||| wraparound "overflows" once every operand of a folded arithmetic
||| chain is a compile-time literal (found via `Test6NativeInts.idr`'s
||| own `chainInt8 100 100`-shaped calls, which this guard exists to
||| keep working) -- but only when the resulting literal chain has an
||| actual chance of reaching Emit unfolded. Everything else
||| Compiler.RC2.ConstFold *does* fold (fixed-width ints, BigInteger,
||| strings) gets computed down to a single RPrimVal by the time
||| Compiler.RC2.RC's `toRCDef` finishes, well before Emit ever sees an
||| arithmetic expression -- so inlining those poses no such risk and
||| is allowed through. Vacuously true for a nullary call, which has no
||| such folding risk at all (nothing to fold), so this only ever
||| actually fires once there's at least one argument.
allLiteralArgs : List (Lifted vars) -> Bool
allLiteralArgs [] = False
allLiteralArgs args = all isPrimVal args && any hasUnfoldableConst args
  where
    hasUnfoldableConst : Lifted vars -> Bool
    hasUnfoldableConst (LPrimVal _ c) = not (safeConst c)
    hasUnfoldableConst _ = False

------------------------------------------------------------------------
-- The whole-program rewrite

-- Walks `e`, replacing every fully-saturated call to a Criterion-A-
-- eligible function with that function's own body, substituted with the
-- call's own (already-processed) arguments. Bottom-up: a call's own
-- arguments are inlined first, so a nested eligible call inside an
-- argument is caught before the outer call is even considered. No
-- second pass over a freshly-spliced body is needed -- Criterion A's own
-- "call-free" requirement guarantees an eligible callee's body has
-- nothing left to inline.
mutual
  inlineLifted : SortedMap Name Eligible -> Lifted vars -> Core (Lifted vars)
  inlineLifted elig (LAppName fc lazy n args)
      = do args' <- traverse (inlineLifted elig) args
           case SortedMap.lookup n elig of
                Just (MkEligible eargs ebody) =>
                    if length eargs == length args' && not (allLiteralArgs args')
                       then do env <- toSubst eargs args'
                               pure $ inlineCall ebody env
                       else pure $ LAppName fc lazy n args'
                Nothing => pure $ LAppName fc lazy n args'
  inlineLifted elig (LUnderApp fc n m args)
      = LUnderApp fc n m <$> traverse (inlineLifted elig) args
  inlineLifted elig (LApp fc lazy c a)
      = LApp fc lazy <$> inlineLifted elig c <*> inlineLifted elig a
  inlineLifted elig (LLet fc x val sc)
      = LLet fc x <$> inlineLifted elig val <*> inlineLifted elig sc
  inlineLifted elig (LCon fc n ci tag args)
      = LCon fc n ci tag <$> traverse (inlineLifted elig) args
  inlineLifted elig (LOp fc lazy op args)
      = LOp fc lazy op <$> traverseVectCore (inlineLifted elig) args
  inlineLifted elig (LExtPrim fc lazy p args)
      = LExtPrim fc lazy p <$> traverse (inlineLifted elig) args
  inlineLifted elig (LConCase fc sc alts def)
      = LConCase fc <$> inlineLifted elig sc <*> traverse (inlineConAlt elig) alts <*> traverseOpt (inlineLifted elig) def
  inlineLifted elig (LConstCase fc sc alts def)
      = LConstCase fc <$> inlineLifted elig sc <*> traverse (inlineConstAlt elig) alts <*> traverseOpt (inlineLifted elig) def
  inlineLifted elig e = pure e

  inlineConAlt : SortedMap Name Eligible -> LiftedConAlt vars -> Core (LiftedConAlt vars)
  inlineConAlt elig (MkLConAlt n ci t args sc) = MkLConAlt n ci t args <$> inlineLifted elig sc

  inlineConstAlt : SortedMap Name Eligible -> LiftedConstAlt vars -> Core (LiftedConstAlt vars)
  inlineConstAlt elig (MkLConstAlt c sc) = MkLConstAlt c <$> inlineLifted elig sc

||| Applies Criterion-A inlining, followed by a case-of-case collapse
||| pass, to every top-level definition's own body -- one pass, not
||| iterated to a fixpoint (see `inlineLifted`'s own module note for why a
||| second pass over a freshly-spliced body is never needed). The
||| eligible-callee map is built once, up front, from the *original*
||| (pre-inlining) definitions -- an eligible callee is call-free by
||| definition, so inlining elsewhere never changes whether it itself
||| stays eligible.
export
applyInlineLifted : List (Name, LiftedDef) -> Core (List (Name, LiftedDef))
applyInlineLifted lds = traverse (inlineDef (buildEligible lds)) lds
  where
    inlineDef : SortedMap Name Eligible -> (Name, LiftedDef) -> Core (Name, LiftedDef)
    inlineDef elig (n, MkLFun args scope body)
        = do body' <- inlineLifted elig body
             pure (n, MkLFun args scope (collapseCaseOfCase body'))
    inlineDef elig (n, MkLError body)
        = do body' <- inlineLifted elig body
             pure (n, MkLError (collapseCaseOfCase body'))
    inlineDef _ d = pure d
