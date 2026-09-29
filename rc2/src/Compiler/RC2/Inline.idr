||| The case-of-case collapse on `Lifted`: a `case` whose scrutinee is
||| itself a `case`, which inlining leaves when it splices a small
||| case-returning callee into a scrutinee, becomes one `case`, so
||| `Compiler.RC2.RC`'s `tryFuseCompare` reaches the comparison. The
||| inlining itself runs earlier, on the case trees
||| (`Compiler.RC2.InlineCExp`). Design: `rc2/doc/inlining.md`.
module Compiler.RC2.Inline

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Compiler.LambdaLift

import Core.CompileExpr
import Core.Context
import Core.Context.Log
import Core.Core
import Core.FC
import Core.TT

import Data.List
import Data.Nat
import Data.SortedMap
import Data.SortedSet
import Data.Vect

import Libraries.Data.List.SizeOf

%default covering

------------------------------------------------------------------------
-- `Weaken` for `Lifted`, ported from `Core.TT.Term`'s own `insertNames`/
-- `GenWeaken` instances: duplicating the outer alternatives under an
-- inner alternative's binders re-indexes them. The `LiftedConAlt` case
-- needs one extra `appendAssociative` reshuffle `Term`'s single-name
-- `Bind` never needed, since a constructor alt binds a whole list of
-- names at once -- ported from `Compiler.CaseOpts`'s own
-- `shiftBinderConAlt`, which solves the identical shape for `CConAlt`.

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

||| A cheap, coarse structural node count -- not calibrated against
||| actual generated-C size, just a proxy for "small helper" to bound how
||| much code a single inlining decision can duplicate across call sites.
||| Moved ahead of the case-of-case section below (originally lived next
||| to `smallBodyThreshold`, in the eligibility section) because
||| `tryCaseOfCase`'s own size-budget guard needs it too -- see that
||| guard's own doc comment for why.
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

||| A tree paired with its own already-known `sizeOf` -- see "Size
||| bookkeeping" below for why this is threaded through instead of
||| calling `sizeOf` fresh wherever a size is needed.
record Sized (a : Type) where
  constructor MkSized
  szOf : Nat
  valOf : a

||| State threaded through `caseOfCaseHere`'s retry loop: the current
||| candidate tree, its own already-known total size, and the size of
||| its own *direct* `alts`/`def` fields specifically (`tryCaseOfCase`'s
||| own `outerSize`) -- see "Size bookkeeping" below.
record CollapseState (vars : Scope) where
  constructor MkCollapseState
  totalSize : Nat
  branchesSize : Nat
  tree : Lifted vars

doCaseOfCase : FC -> (x : Lifted vars) -> (xalts : List (LiftedConAlt vars)) -> (xdef : Maybe (Lifted vars)) ->
               (alts : List (LiftedConAlt vars)) -> (def : Maybe (Lifted vars)) -> (outerSize : Nat) -> CollapseState vars
doCaseOfCase fc x xalts xdef alts def outerSize
    -- Bound once: a `where` value is re-evaluated at every reference
    -- (doc/constant-constructor-specialization.md, "The `where`-clause
    -- trap").
    = let nb : Nat := newBranchesSize in
      MkCollapseState (1 + sizeOf x + nb) nb
                      (LConCase fc x (map updateAlt xalts) (map updateDef xdef))
  where
    duplicationCount : Nat
    duplicationCount = length xalts + maybe 0 (const 1) xdef
    -- Every duplicated copy of `alts`/`def` gains one extra node (the
    -- fresh `LConCase fc sc alts def` wrapper `updateAlt`/`updateDef`
    -- introduce around it) on top of `outerSize` itself -- see "Size
    -- bookkeeping" below for the full derivation.
    newBranchesSize : Nat
    newBranchesSize = sum (map sizeOfConAlt xalts) + maybe 0 sizeOf xdef + duplicationCount * (1 + outerSize)
    updateAlt : LiftedConAlt vars -> LiftedConAlt vars
    updateAlt (MkLConAlt n ci t args sc)
        = MkLConAlt n ci t args $
              LConCase fc sc (map (weakenNs (mkSizeOf args)) alts) (map (weakenNs (mkSizeOf args)) def)
    updateDef : Lifted vars -> Lifted vars
    updateDef sc = LConCase fc sc alts def

doCaseOfConstCase : FC -> (x : Lifted vars) -> (xalts : List (LiftedConstAlt vars)) -> (xdef : Maybe (Lifted vars)) ->
                     (alts : List (LiftedConstAlt vars)) -> (def : Maybe (Lifted vars)) -> (outerSize : Nat) -> CollapseState vars
doCaseOfConstCase fc x xalts xdef alts def outerSize
    -- Bound once: a `where` value is re-evaluated at every reference
    -- (doc/constant-constructor-specialization.md, "The `where`-clause
    -- trap").
    = let nb : Nat := newBranchesSize in
      MkCollapseState (1 + sizeOf x + nb) nb
                      (LConstCase fc x (map updateAlt xalts) (map updateDef xdef))
  where
    duplicationCount : Nat
    duplicationCount = length xalts + maybe 0 (const 1) xdef
    newBranchesSize : Nat
    newBranchesSize = sum (map sizeOfConstAlt xalts) + maybe 0 sizeOf xdef + duplicationCount * (1 + outerSize)
    updateAlt : LiftedConstAlt vars -> LiftedConstAlt vars
    updateAlt (MkLConstAlt c sc) = MkLConstAlt c $ LConstCase fc sc alts def
    updateDef : Lifted vars -> Lifted vars
    updateDef sc = LConstCase fc sc alts def

||| To minimise the risk of code-size blowup from duplicating the outer
||| case into every inner branch, only collapse when the inner case's own
||| alternatives are all constructor-headed (or there's only one, with no
||| default) -- identical restriction to upstream's own `canCaseOfCase`.
|||
||| That restriction alone isn't enough for *this* pass, though (unlike
||| upstream's own `Compiler.Inline`, whose default inlining heuristic
||| -- `Compiler.Opts.InlineHeuristics`'s own `simple` -- explicitly
||| excludes any callee whose body is itself a `CConCase`/`CConstCase`,
||| so upstream's `caseOfCase` only ever fires on nesting already present
||| in the source, never on nesting *its own* inliner just created):
||| Criterion A (`Compiler.RC2.InlineCExp`) deliberately targets exactly the opposite shape --
||| a small callee whose body *is* a case (e.g. `Ord Int`'s `<=`) is the
||| whole point, so it can be spliced into a scrutinee position and then
||| collapsed here, letting `Compiler.RC2.RC`'s `tryFuseCompare` reach it.
||| A chain of such splices sitting in nested (or sibling, alt-nested --
||| e.g. a run of `if p1 x then (if p2 y then ... else ...) else ...`
||| guards, each `pI` a small case-returning predicate) call sites can
||| then compound *multiplicatively*: each `doCaseOfCase` duplicates the
||| entire, already-collapsed outer `alts`/`def` once per inner branch,
||| and since this whole pass runs bottom-up (a node's own children,
||| duplication from a lower collapse included, are already fully
||| realised by the time this check runs on their parent), that
||| per-level duplication factor multiplies across every level of a
||| chain. Confirmed empirically (see `rc2/doc/inlining.md`'s own "Size
||| budget" section): an N-deep synthetic guard chain of exactly this
||| shape produced generated-C line counts that roughly *doubled* per
||| additional level (19,041 / 37,473 / 74,337 lines at N=10/11/12,
||| vs. 1,044 lines for the same source with `--directive noinline`),
||| eventually exhausting memory outright around N=15.
|||
||| The guard below bounds this the same way `smallBodyThreshold` bounds
||| Criterion A itself: compute what a collapse *would* duplicate (the
||| outer `alts`/`def`, already in their final, bottom-up-processed
||| form) and how many places it would land in, and skip the collapse
||| once that product crosses a fixed budget. Skipping is always safe --
||| the result is just the original, uncollapsed `case (case ...) of
||| ...`, correct but unfused past that point -- and because the check
||| uses the *already-realised* (i.e. already-duplicated-so-far) size of
||| `alts`/`def`, a chain that would otherwise keep compounding gets
||| capped at the first level where cumulative size crosses the budget;
||| every level beyond that sees an input already at or near budget and
||| keeps skipping, rather than resuming the multiplication.
|||
||| `outerSize` itself is *not* recomputed here -- see "Size
||| bookkeeping" below.
caseOfCaseSizeBudget : Nat
caseOfCaseSizeBudget = 200

tryCaseOfCase : CollapseState vars -> Maybe (CollapseState vars)
tryCaseOfCase (MkCollapseState _ outerSize (LConCase fc (LConCase fc' x xalts xdef) alts def))
    = if canCaseOfCase xalts xdef && collapseSizeOk then Just (doCaseOfCase fc' x xalts xdef alts def outerSize) else Nothing
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
    duplicationCount : Nat
    duplicationCount = length xalts + maybe 0 (const 1) xdef
    collapseSizeOk : Bool
    collapseSizeOk = duplicationCount * outerSize <= caseOfCaseSizeBudget
tryCaseOfCase (MkCollapseState _ outerSize (LConstCase fc (LConstCase fc' x xalts xdef) alts def))
    = if canCaseOfCase xalts xdef && collapseSizeOk then Just (doCaseOfConstCase fc' x xalts xdef alts def outerSize) else Nothing
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
    duplicationCount : Nat
    duplicationCount = length xalts + maybe 0 (const 1) xdef
    collapseSizeOk : Bool
    collapseSizeOk = duplicationCount * outerSize <= caseOfCaseSizeBudget
tryCaseOfCase _ = Nothing

||| Collapse a single node, retrying up to a small, fixed depth (matching
||| upstream's own `caseOfCase`) -- a chain of more than a handful of
||| nested case-of-case shapes at one spot is not a pattern this pass's
||| own inlining is expected to ever actually produce.
caseOfCaseHere : CollapseState vars -> CollapseState vars
caseOfCaseHere st = go 5 st
  where
    go : Nat -> CollapseState vars -> CollapseState vars
    go Z st = st
    go (S k) st = maybe st (go k) (tryCaseOfCase st)

-- Applies `caseOfCaseHere` throughout the whole tree, bottom-up (a
-- node's own children are collapsed first, so the collapse check at
-- this node sees its scrutinee already in its own final, smallest
-- form).
--
-- ## Size bookkeeping
--
-- `tryCaseOfCase`'s own size-budget guard needs `outerSize` (the
-- current node's own `alts`/`def` size) at every candidate site.
-- Computing it via a fresh top-down `sizeOf`/`sizeOfConAlt` scan (as an
-- earlier version of this guard did) re-walks `alts`/`def` from
-- scratch at *every* site -- for a large real program with many
-- scattered case-of-case candidates (not just one pathological guard
-- chain), each re-walking its own, unboundedly large enclosing
-- `alts`/`def`, this dominated `rc2: Inline`'s own wall-clock time
-- outright (measured 144s on a large real program, where `rc2: RC
-- normalize` immediately after showed no inline-vs-`noinline`
-- difference at all -- confirming the cost sat *inside* this pass, not
-- downstream of it).
--
-- Fix: thread the size alongside the tree throughout, computed
-- incrementally as this traversal already builds each node bottom-up
-- (`collapseCaseOfCase`/`collapseConAlt`/`collapseConstAlt` return
-- `Sized`), and update it via a closed-form formula on every
-- *successful* collapse (`doCaseOfCase`/`doCaseOfConstCase`'s own
-- `newBranchesSize`) rather than re-deriving it from the result.
-- `weakenNs` (re-indexing a duplicated copy of `alts`/`def` into a
-- deeper scope) never changes node count, so a duplicated copy's size
-- is always exactly `outerSize`; each of the `duplicationCount` copies
-- also gains the one `LConCase`/`LConstCase` wrapper node
-- `updateAlt`/`updateDef` builds around it, hence `1 + outerSize` per
-- copy. `xalts`/`xdef` (the *inner*, just-spliced-in side, as opposed
-- to `alts`/`def`) are cheap to scan fresh regardless -- when produced
-- by this pass's own inlining they're bounded by Criterion A's own
-- `smallBodyThreshold`, and when they instead come from a genuinely
-- large, naturally-nested source `case` this was already exactly as
-- expensive before any of this bookkeeping existed, so no new cost is
-- introduced there. `CollapseState`'s own `totalSize` similarly avoids
-- a fresh whole-subtree re-scan on every one of `caseOfCaseHere`'s own
-- (up to 5) retries at one tree position.
mutual
  collapseCaseOfCase : Lifted vars -> Sized (Lifted vars)
  collapseCaseOfCase (LAppName fc lazy n args)
      = let args' = map collapseCaseOfCase args
        in MkSized (1 + sum (map szOf args')) (LAppName fc lazy n (map valOf args'))
  collapseCaseOfCase (LUnderApp fc n m args)
      = let args' = map collapseCaseOfCase args
        in MkSized (1 + sum (map szOf args')) (LUnderApp fc n m (map valOf args'))
  collapseCaseOfCase (LApp fc lazy c a)
      = let c' = collapseCaseOfCase c
            a' = collapseCaseOfCase a
        in MkSized (1 + szOf c' + szOf a') (LApp fc lazy (valOf c') (valOf a'))
  collapseCaseOfCase (LLet fc x val sc)
      = let val' = collapseCaseOfCase val
            sc' = collapseCaseOfCase sc
        in MkSized (1 + szOf val' + szOf sc') (LLet fc x (valOf val') (valOf sc'))
  collapseCaseOfCase (LCon fc n ci tag args)
      = let args' = map collapseCaseOfCase args
        in MkSized (1 + sum (map szOf args')) (LCon fc n ci tag (map valOf args'))
  collapseCaseOfCase (LOp fc lazy op args)
      = let args' = map collapseCaseOfCase args
        in MkSized (1 + sum (toList (map szOf args'))) (LOp fc lazy op (map valOf args'))
  collapseCaseOfCase (LExtPrim fc lazy p args)
      = let args' = map collapseCaseOfCase args
        in MkSized (1 + sum (map szOf args')) (LExtPrim fc lazy p (map valOf args'))
  collapseCaseOfCase (LConCase fc sc alts def)
      = let scS = collapseCaseOfCase sc
            altsS = map collapseConAlt alts
            defS = map collapseCaseOfCase def
            outerSize0 = sum (map szOf altsS) + maybe 0 szOf defS
            node0 = LConCase fc (valOf scS) (map valOf altsS) (map valOf defS)
            final = caseOfCaseHere (MkCollapseState (1 + szOf scS + outerSize0) outerSize0 node0)
        in MkSized (totalSize final) (tree final)
  collapseCaseOfCase (LConstCase fc sc alts def)
      = let scS = collapseCaseOfCase sc
            altsS = map collapseConstAlt alts
            defS = map collapseCaseOfCase def
            outerSize0 = sum (map szOf altsS) + maybe 0 szOf defS
            node0 = LConstCase fc (valOf scS) (map valOf altsS) (map valOf defS)
            final = caseOfCaseHere (MkCollapseState (1 + szOf scS + outerSize0) outerSize0 node0)
        in MkSized (totalSize final) (tree final)
  collapseCaseOfCase e = MkSized 1 e

  collapseConAlt : LiftedConAlt vars -> Sized (LiftedConAlt vars)
  collapseConAlt (MkLConAlt n ci t args sc)
      = let sc' = collapseCaseOfCase sc
        in MkSized (szOf sc') (MkLConAlt n ci t args (valOf sc'))

  collapseConstAlt : LiftedConstAlt vars -> Sized (LiftedConstAlt vars)
  collapseConstAlt (MkLConstAlt c sc)
      = let sc' = collapseCaseOfCase sc
        in MkSized (szOf sc') (MkLConstAlt c (valOf sc'))

||| The case-of-case collapse over every function and error body.
export
applyCaseOfCase : List (Name, LiftedDef) -> List (Name, LiftedDef)
applyCaseOfCase = map collapseDef
  where
    collapseDef : (Name, LiftedDef) -> (Name, LiftedDef)
    collapseDef (n, MkLFun args scope body) = (n, MkLFun args scope (valOf (collapseCaseOfCase body)))
    collapseDef (n, MkLError body) = (n, MkLError (valOf (collapseCaseOfCase body)))
    collapseDef d = d
