module Compiler.RC2.RCExp

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Explicit reference-counted IR for `rc2`.
-- Reference counting is handled via three explicit nodes:
--   * `RDup`: Increment refcount.
--   * `RDrop`: Decrement refcount, recursively free if zero.
--   * `RFree`: Unconditionally free, used for provably unshared fresh values.
--
-- Optimization note: Constructor reuse is decided by `Compiler.RC2.Reuse`
-- and encoded directly on this IR.
-- `Compiler.RC2.Emit` mechanically lowers this IR to C.

import Core.CompileExpr
import Core.FC
import Core.TT

import Data.SortedSet
import Data.Vect

%default covering

||| ANF-position value: a variable or a constant (see
||| `doc/reading-the-ir.md`'s "## 3. Values" for the full syntax
||| reference). `RCNull`/`RCEmptyCon` fold NIL/NOTHING/ZERO/UNIT and
||| other zero-arg constructors into C's NULL/a tagged integer, rather
||| than a genuine heap constructor.
public export
data RCLocal : Type where
     RCLoc      : Int -> RCLocal
     RCNull     : RCLocal
     RCConst    : Constant -> RCLocal
     RCEmptyCon : Name -> ConInfo -> Int -> RCLocal

export
Eq RCLocal where
  (RCLoc i1) == (RCLoc i2) = i1 == i2
  RCNull == RCNull = True
  (RCConst c1) == (RCConst c2) = c1 == c2
  (RCEmptyCon n1 _ t1) == (RCEmptyCon n2 _ t2) = n1 == n2 && t1 == t2
  _ == _ = False

export
Ord RCLocal where
  compare (RCLoc i1)      (RCLoc i2)      = compare i1 i2
  compare (RCLoc _)       RCNull          = GT
  compare (RCLoc _)       (RCConst _)     = GT
  compare (RCLoc _)       (RCEmptyCon {}) = GT
  compare RCNull          (RCLoc _)       = LT
  compare RCNull          RCNull          = EQ
  compare RCNull          (RCConst _)     = GT
  compare RCNull          (RCEmptyCon {}) = GT
  compare (RCConst _)     (RCLoc _)       = LT
  compare (RCConst _)     RCNull          = LT
  compare (RCConst c1)    (RCConst c2)    = compare c1 c2
  compare (RCConst _)     (RCEmptyCon {}) = GT
  compare (RCEmptyCon {}) (RCLoc _)       = LT
  compare (RCEmptyCon {}) RCNull          = LT
  compare (RCEmptyCon {}) (RCConst _)     = LT
  compare (RCEmptyCon n1 _ t1) (RCEmptyCon n2 _ t2) = compare n1 n2 <+> compare t1 t2

export
Show RCLocal where
  show (RCLoc i) = "v" ++ show i
  show RCNull = "[__]"
  show (RCConst c) = "#" ++ show c
  show (RCEmptyCon n _ t) = "#" ++ show n ++ "@" ++ show t

||| The representation decided for an RLet-bound local, carried
||| directly on the RLet node (see `doc/reading-the-ir.md`'s
||| "## 4. Representation" and `doc/native-type-inference.md`).
||| `RInlineNative` is a Phase 2 (`annotate`) refinement of a plain
||| `RNative`: a native op with no Boxed operands (`ROp.postDrop == []`),
||| used exactly once, safe to splice inline instead of declaring a C
||| variable -- Phase 1 never produces this directly, only Phase 2
||| promotes into it.
public export
data Rep = RBoxed | RNative PrimType | RInlineNative PrimType

mutual
  public export
  data RCExp : Type where
       RV         : FC -> RCLocal -> RCExp
       RAppName   : FC -> (lazy : Maybe LazyReason) -> Name -> List RCLocal -> RCExp
       ||| Direct, saturated call to `name`'s own dual-ABI worker variant
       ||| (see `Compiler.RC2.DualABI`); `argReps`/`retRep` describe how
       ||| *this* call renders each argument/its result. Never valid in
       ||| a closure-building position -- a closure slot can only ever
       ||| hold `IDRIS2RC2_Value *`. Only produced by
       ||| `Compiler.RC2.DualABI`, strictly after `Compiler.RC2.Loop`.
       ||| `postDrop` mirrors `ROp`'s own field -- see
       ||| `doc/native-type-inference.md`'s "What's stored on the IR
       ||| vs. re-derived" and `doc/dual-abi.md`'s Bugs found #3 for the
       ||| full rationale and the leak it fixes.
       RAppNameRep : FC -> Name -> (argReps : List Rep) -> (retRep : Rep) -> (postDrop : List RCLocal) -> List RCLocal -> RCExp
       RUnderApp  : FC -> Name -> (missing : Nat) -> List RCLocal -> RCExp
       RApp       : FC -> (lazy : Maybe LazyReason) -> RCLocal -> RCLocal -> RCExp
       ||| `rep`: this local's representation (see `Rep`,
       ||| `doc/native-type-inference.md`). A dead-on-arrival binding
       ||| (never used in `body`) has no separate flag -- `body` is just
       ||| wrapped in an ordinary RDrop/RFree for it, like anywhere else.
       RLet       : FC -> (var : Int) -> Rep -> RCExp -> RCExp -> RCExp
       ||| `reuseFrom`: if `Just loc`, this constructor's allocation may
       ||| reuse `loc`'s storage (a dying same-shape constructor offered
       ||| by an enclosing `RReuseOffer`). Decided by
       ||| `Compiler.RC2.Reuse`'s `resolveReuse`, run after Phase 1/2 --
       ||| see `doc/reuse-analysis.md`'s "IR additions". Phase 1/2
       ||| always leave this `Nothing`.
       RCon       : FC -> Name -> ConInfo -> (tag : Maybe Int) -> List RCLocal -> (reuseFrom : Maybe RCLocal) -> RCExp
       ||| `postDrop`: every Boxed operand this op needs dropped once
       ||| it's done reading it (one entry per *occurrence* in `args`,
       ||| so an operand read twice, e.g. `x + x`, appears twice) --
       ||| decided by Compiler.RC2.RC's `annotate` (Phase 2), carried
       ||| directly on the node so Emit.idr only ever lowers it rather
       ||| than re-deriving "which operands are Boxed" at emission time.
       ||| Phase 1 always constructs this as `[]`; only Phase 2 fills it
       ||| in. See `doc/native-type-inference.md`'s "What's stored on
       ||| the IR vs. re-derived" -- the canonical explanation every
       ||| other `postDrop` field in this file points back to.
       ROp        : {0 arity : Nat} -> FC -> (lazy : Maybe LazyReason) -> PrimFn arity -> Vect arity RCLocal -> (postDrop : List RCLocal) -> RCExp
       RExtPrim   : FC -> (lazy : Maybe LazyReason) -> Name -> List RCLocal -> RCExp
       ||| A read of one field out of a C struct pointer (see
       ||| `doc/c-struct-support.md`). `structName`/`fieldName` stay
       ||| plain strings, resolved against a whole-program struct-field
       ||| table built once in `Compiler.RC2.Emit`'s own
       ||| `generateCSourceFile`, the same way `RPrimVal`'s own
       ||| `dyngen`/`orStagen` resolve a literal's concrete C rendering
       ||| late rather than pre-resolving it here. `postDrop` mirrors
       ||| `ROp`'s own field, but a plain C pointer dereference never
       ||| needs a `dup` the way an `ROp` operand can -- `postDrop`
       ||| here only ever means "drop `structVar`, this was its last
       ||| use", never "drop after an inserted `dup`". Phase 1 always
       ||| constructs this as `[]`; only Phase 2 fills it in.
       RStructGet : FC -> (structVar : RCLocal) -> (structName : String) -> (fieldName : String) -> (postDrop : List RCLocal) -> RCExp
       ||| A write of one field into a C struct pointer, evaluating to
       ||| Unit. Same reasoning as `RStructGet` for both `structVar`
       ||| and `value` -- neither is ever duplicated, `postDrop` (0, 1,
       ||| or 2 elements) only ever means "this was this operand's own
       ||| last use". See `doc/c-struct-support.md`.
       RStructSet : FC -> (structVar : RCLocal) -> (structName : String) -> (fieldName : String) -> (value : RCLocal) -> (postDrop : List RCLocal) -> RCExp
       ||| A boolean comparison (LT/GT/EQ/LTE/GTE) fused directly into a
       ||| two-way branch, with the Bool it would otherwise produce
       ||| never materialised as a value. Only produced by Phase 1
       ||| `normalize`'s `tryFuseCompare` -- see
       ||| `doc/native-type-inference.md`'s "Comparisons are a
       ||| separate, narrower mechanism". `postDrop` mirrors `ROp`'s
       ||| own field above; Phase 1 always constructs this as `[]`,
       ||| only Phase 2 fills it in.
       RCmpCase   : FC -> PrimFn 2 -> Vect 2 RCLocal -> (postDrop : List RCLocal) -> (whenTrue : RCExp) -> (whenFalse : RCExp) -> RCExp
       RConCase   : FC -> RCLocal -> List RConAlt -> Maybe RCExp -> RCExp
       RConstCase : FC -> RCLocal -> List RConstAlt -> Maybe RCExp -> RCExp
       RPrimVal   : FC -> Constant -> RCExp
       RErased    : FC -> RCExp
       RCrash     : FC -> String -> RCExp
       ||| "add": increment `loc`'s refcount, then continue. See the module
       ||| note -- this is what a borrowed use of a variable lowers to.
       RDup       : FC -> RCLocal -> RCExp -> RCExp
       ||| Explicit cleanup of owned variables that are dead at this point,
       ||| wrapping the rest of the computation. Emit lowers each of these
       ||| to `idris2rc2_drop(...)` calls, except for any it decides to
       ||| fold into a constructor-reuse slot instead (see module note).
       RDrop      : FC -> List RCLocal -> RCExp -> RCExp
       ||| Unconditional, unchecked deallocation of `loc`, then continue.
       ||| See the module note: only ever inserted where RC.idr can prove
       ||| statically that `loc` is a brand-new, never-shared allocation.
       RFree      : FC -> RCLocal -> RCExp -> RCExp
       ||| Releases a reuse candidate (`RReuseOffer`) not consumed by
       ||| any `RCon` on this execution path -- lowers to
       ||| `idris2rc2_dropReuseConstructor(loc)`, a no-op if the
       ||| uniqueness check that created the offer already failed. Only
       ||| inserted by `Compiler.RC2.Reuse` -- see
       ||| `doc/reuse-analysis.md`'s "IR additions".
       RReleaseReuse : FC -> RCLocal -> RCExp -> RCExp
       ||| Explicit tail-recursive loop: `loopParams` are this loop's
       ||| own carried locals, each with an independent `Rep`; `initial`
       ||| supplies their starting values, evaluated once in the
       ||| enclosing scope. `body` runs repeatedly -- an `RLoopContinue`
       ||| reachable in tail position starts the next iteration;
       ||| anything else exits with that value. `prologueDrop`:
       ||| top-level args that got a native shadow here and are
       ||| therefore dead in their original Boxed form once the shadow
       ||| declarations run. Only produced by `Compiler.RC2.Loop`'s
       ||| `applyLoop`. See `doc/loop-conversion.md`'s "IR shape" for
       ||| the full field-by-field walkthrough and "`stripOwnership`"
       ||| for why `prologueDrop` (unlike `initial`/`loopParams`) must
       ||| also be filtered by DualABI's `synthesizeWorker`.
       RLoop : FC -> (loopParams : List (Int, Rep)) -> (initial : List RCLocal) -> (prologueDrop : List RCLocal) -> RCExp -> RCExp
       ||| Continue the nearest enclosing `RLoop`, supplying `args` as
       ||| each loop param's new value. `args`'s own ownership is
       ||| untouched by this node's introduction -- `annotate` (Phase 2)
       ||| already computed the right dup/move decisions before
       ||| `Compiler.RC2.Loop` ever ran, and those decisions are
       ||| preserved as-is (only the terminal `RAppName` is swapped).
       ||| See `doc/loop-conversion.md`'s "`applyLoop`" section.
       |||
       ||| `postDrop` mirrors `ROp`'s own field (a *separate* concern
       ||| `annotate` never touches, since this node doesn't exist yet
       ||| when it runs) -- decided by `applyLoop` once every loop
       ||| param's final `Rep` is known. A real, `valgrind`-confirmed
       ||| leak was found from this field's own absence -- see
       ||| `doc/loop-conversion.md`'s "Bugs found and fixed" #5.
       RLoopContinue : FC -> List RCLocal -> (postDrop : List RCLocal) -> RCExp
       ||| Runtime uniqueness check deciding whether `sc`'s storage can
       ||| be repurposed for a later `RCon` of the same shape
       ||| (`RCon.reuseFrom`) instead of allocating fresh: if `sc` is
       ||| unique, its storage is reserved; otherwise every
       ||| `dupOnShared` entry (destructured straight out of `sc`, plain
       ||| pointer aliasing) is dup'd before `sc` drops normally. Either
       ||| way execution continues into `body` -- a setup step with two
       ||| ways of getting there, not a two-armed branch. Exactly one
       ||| reachable `RCon` claims the offer; every other path gets an
       ||| `RReleaseReuse sc` instead. Only inserted by
       ||| `Compiler.RC2.Reuse`'s `resolveAlt` (replaces the old
       ||| `MkRConAlt.offersReuse` flag). See `doc/reuse-analysis.md`'s
       ||| "IR additions" for this node's semantics and "`resolveAlt`"/
       ||| "`tryConsume`/`tryClaim`" for the algorithm.
       RReuseOffer : FC -> (sc : RCLocal) -> (dupOnShared : List RCLocal) -> RCExp -> RCExp

  public export
  data RConAlt : Type where
       MkRConAlt : Name -> ConInfo -> (tag : Maybe Int) -> (args : List Int) -> RCExp -> RConAlt

  public export
  data RConstAlt : Type where
       MkRConstAlt : Constant -> RCExp -> RConstAlt

||| `MkRCFun`'s own top-level parameters, each with its own `Rep` --
||| foundation for the dual (Boxed/native) calling convention (`RBoxed`
||| = an ordinary `IDRIS2RC2_Value *`, `RNative ty` = a raw native C
||| scalar the caller supplies directly); `retRep` is the same idea for
||| the return value. Currently always `RBoxed` everywhere -- pure
||| IR-shape groundwork, no pass promotes a parameter/return yet. See
||| `doc/dual-abi.md`'s "`MkRCFun`'s new shape (Stage 1)".
public export
data RCDef : Type where
     MkRCFun : (args : List (Int, Rep)) -> (retRep : Rep) -> RCExp -> RCDef
     MkRCCon : (tag : Maybe Int) -> (arity : Nat) -> (nt : Maybe Nat) -> RCDef
     MkRCForeign : (ccs : List String) -> (fargs : List CFType) -> CFType -> RCDef
     MkRCError : RCExp -> RCDef

------------------------------------------------------------------------
-- Structural analyses used by RC.idr (ownership annotation) and
-- Compiler.RC2.Reuse (constructor-reuse-in-place bookkeeping).

export
freeLocalsR : RCExp -> SortedSet RCLocal
freeLocalsR (RV _ v) = singleton v
freeLocalsR (RAppName _ _ _ args) = fromList args
freeLocalsR (RUnderApp _ _ _ args) = fromList args
freeLocalsR (RApp _ _ c a) = fromList [c, a]
freeLocalsR (RLet _ var _ value body) =
    union (freeLocalsR value) (delete (RCLoc var) (freeLocalsR body))
-- `reuseFrom` isn't counted here (or in countUsesR below) -- like
-- ROp's postDrop, the local it names is already counted via its own
-- real binding site (the enclosing RConCase's `sc`), so adding it
-- again would only be redundant, never additive.
freeLocalsR (RCon _ _ _ _ args _) = fromList args
freeLocalsR (ROp _ _ _ args _) = fromList (toList args)
freeLocalsR (RExtPrim _ _ _ args) = fromList args
freeLocalsR (RStructGet _ structVar _ _ _) = singleton structVar
freeLocalsR (RStructSet _ structVar _ _ value _) = fromList [structVar, value]
freeLocalsR (RCmpCase _ _ args _ t f) =
    union (fromList (toList args)) (union (freeLocalsR t) (freeLocalsR f))
freeLocalsR (RConCase _ sc alts mDef) =
    let altsFree = map (\(MkRConAlt _ _ _ args body) =>
                          difference (freeLocalsR body) (fromList (map RCLoc args))) alts
        allFree = maybe altsFree (\d => freeLocalsR d :: altsFree) mDef
    in insert sc (concat allFree)
freeLocalsR (RConstCase _ sc alts mDef) =
    let altsFree = map (\(MkRConstAlt _ body) => freeLocalsR body) alts
        allFree = maybe altsFree (\d => freeLocalsR d :: altsFree) mDef
    in insert sc (concat allFree)
freeLocalsR (RDup _ v body) = insert v (freeLocalsR body)
freeLocalsR (RDrop _ vars body) = union (fromList vars) (freeLocalsR body)
freeLocalsR (RFree _ v body) = insert v (freeLocalsR body)
freeLocalsR (RReleaseReuse _ v body) = insert v (freeLocalsR body)
freeLocalsR (RReuseOffer _ sc dupOnShared body) =
    union (insert sc (fromList dupOnShared)) (freeLocalsR body)
freeLocalsR _ = empty

||| How many times `l` is referenced anywhere in `e` -- unlike
||| `freeLocalsR`'s set (which collapses repeats), RC.idr's
||| `inlineableRep` needs the exact count to tell "referenced exactly
||| once, safe to splice its defining expression in at that one site
||| instead of declaring a variable" apart from "referenced more than
||| once, inlining would duplicate its computation."
export
countUsesR : RCLocal -> RCExp -> Nat
countUsesR l (RV _ v) = if v == l then 1 else 0
countUsesR l (RAppName _ _ _ args) = length (filter (== l) args)
countUsesR l (RUnderApp _ _ _ args) = length (filter (== l) args)
countUsesR l (RApp _ _ c a) = length (filter (== l) [c, a])
countUsesR l (RLet _ _ _ value body) = countUsesR l value + countUsesR l body
countUsesR l (RCon _ _ _ _ args _) = length (filter (== l) args)
countUsesR l (ROp _ _ _ args _) = length (filter (== l) (toList args))
countUsesR l (RExtPrim _ _ _ args) = length (filter (== l) args)
countUsesR l (RStructGet _ structVar _ _ _) = if structVar == l then 1 else 0
countUsesR l (RStructSet _ structVar _ _ value _) = length (filter (== l) [structVar, value])
countUsesR l (RCmpCase _ _ args _ t f) =
    length (filter (== l) (toList args)) + countUsesR l t + countUsesR l f
countUsesR l (RConCase _ sc alts mDef) =
    (if sc == l then 1 else 0)
    + sum (map (\(MkRConAlt _ _ _ _ body) => countUsesR l body) alts)
    + maybe 0 (countUsesR l) mDef
countUsesR l (RConstCase _ sc alts mDef) =
    (if sc == l then 1 else 0)
    + sum (map (\(MkRConstAlt _ body) => countUsesR l body) alts)
    + maybe 0 (countUsesR l) mDef
countUsesR l (RDup _ v body) = (if v == l then 1 else 0) + countUsesR l body
countUsesR l (RDrop _ vars body) = length (filter (== l) vars) + countUsesR l body
countUsesR l (RFree _ v body) = (if v == l then 1 else 0) + countUsesR l body
countUsesR l (RReleaseReuse _ v body) = (if v == l then 1 else 0) + countUsesR l body
countUsesR l (RReuseOffer _ sc dupOnShared body) =
    (if sc == l then 1 else 0) + length (filter (== l) dupOnShared) + countUsesR l body
countUsesR l _ = 0

export
usedConstructorsR : RCExp -> SortedSet Name
usedConstructorsR (RLet _ _ _ value body) = union (usedConstructorsR value) (usedConstructorsR body)
usedConstructorsR (RCon _ n _ _ _ _) = singleton n
usedConstructorsR (RCmpCase _ _ _ _ t f) = union (usedConstructorsR t) (usedConstructorsR f)
usedConstructorsR (RConCase _ _ alts mDef) =
    let altsCons = map (\(MkRConAlt _ _ _ _ body) => usedConstructorsR body) alts
    in concat (maybe altsCons (\d => usedConstructorsR d :: altsCons) mDef)
usedConstructorsR (RConstCase _ _ alts mDef) =
    let altsCons = map (\(MkRConstAlt _ body) => usedConstructorsR body) alts
    in concat (maybe altsCons (\d => usedConstructorsR d :: altsCons) mDef)
usedConstructorsR (RDup _ _ body) = usedConstructorsR body
usedConstructorsR (RDrop _ _ body) = usedConstructorsR body
usedConstructorsR (RFree _ _ body) = usedConstructorsR body
usedConstructorsR (RReleaseReuse _ _ body) = usedConstructorsR body
usedConstructorsR (RReuseOffer _ _ _ body) = usedConstructorsR body
usedConstructorsR _ = empty
