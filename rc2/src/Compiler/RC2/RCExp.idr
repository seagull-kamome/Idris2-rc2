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

import Data.List.Quantifiers
import Data.SortedSet
import Data.Vect

%default covering

-- `RCLocal` and `IsAnyConstLocal` are mutually recursive (RCConstCon's
-- own `argsConst` field needs `IsAnyConstLocal`; `IsAnyConstLocal`'s own
-- constructors index into `RCLocal`'s) -- forward-declared here instead
-- of grouping everything below into one `mutual` block, since
-- `IsConstLocal`/`IsConstClosureLocal` only ever reference `RCLocal`,
-- never the reverse, and don't need forward declaring at all.
data RCLocal : Type
data IsAnyConstLocal : RCLocal -> Type

||| ANF-position value: a variable or a constant (see
||| `doc/reading-the-ir.md`'s "## 3. Values" for the full syntax
||| reference). `RCNull`/`RCEmptyCon` fold NIL/NOTHING/ZERO/UNIT and
||| other zero-arg constructors into C's NULL/a tagged integer, rather
||| than a genuine heap constructor. `RCConstCon` folds a constructor
||| application whose fields are themselves all constant (see
||| `Compiler.RC2.ConstFold`) into a single value staged once as a
||| file-scope static (`Compiler.RC2.Emit.Util`'s `ConstConDef`), immortal
||| the same way a small-int-cache/`ConstDef` value is -- never a
||| freshly-allocated heap constructor.
public export
data RCLocal : Type where
     RCLoc      : Int -> RCLocal
     RCNull     : RCLocal
     RCConst    : Constant -> RCLocal
     RCEmptyCon : Name -> ConInfo -> Int -> RCLocal
     ||| `argsConst` is the type-level enforcement of the old
     ||| comment-only invariant "every element of `args` is itself one
     ||| of `RCLocal`'s constant forms, never `RCLoc`" -- erased
     ||| (`0`), so it costs nothing at runtime, but makes constructing
     ||| an ill-formed `RCConstCon` (one holding a live variable
     ||| reference) a compile error rather than a `Compiler.RC2.Emit.Util`
     ||| `idris_crash`. Staying erased all the way through
     ||| (`Compiler.RC2.Emit.Util`'s own `boxedConstConExpr`/
     ||| `constConFieldExprsFor` thread it onward at `0` too, never
     ||| widening it to a kept value) is exactly what lets Idris2
     ||| still use it to rule out the `RCLoc` case in
     ||| `constConFieldExpr`'s coverage check, without this proof
     ||| existing at runtime at all. Only ever constructed by
     ||| `Compiler.RC2.ConstFold`.
     RCConstCon : Name -> ConInfo -> (tag : Maybe Int)
               -> (args : List RCLocal) -> {0 argsConst : All IsAnyConstLocal args}
               -> RCLocal
     ||| A zero-filled closure over a named top-level function --
     ||| `Compiler.RC2.ConstFold`'s own fold of a literal, zero-args
     ||| `RUnderApp fc n missing []` (a bare reference to `n`, no
     ||| captured values) into a constant, the same way `RCConstCon`
     ||| folds a constructor of provably-constant fields. Unlike
     ||| `RCConstCon`, this is a true leaf: a zero-filled closure has
     ||| no captured args at all, so there's no nested `RCLocal` to
     ||| recurse into. Only ever constructed by
     ||| `Compiler.RC2.ConstFold`.
     RCConstClosure : Name -> (missing : Nat) -> RCLocal

||| Witness that `l` is `RCConstCon` -- kept as its own narrow proof
||| (rather than only the five-case `IsAnyConstLocal` below)
||| specifically so `Compiler.RC2.Emit.Util`'s `boxedConstConExpr`, which
||| only ever handles this one case, can require exactly it and let
||| Idris2's coverage checker rule out every other `RCLocal`
||| constructor (`RCLoc` included) as ill-typed, rather than needing a
||| runtime `idris_crash` fallback for the ones it can't otherwise
||| exclude.
public export
data IsConstLocal : RCLocal -> Type where
     ItIsConstCon : IsConstLocal (RCConstCon n ci t args)

||| Witness that `l` is `RCConstClosure` -- the closure-emission
||| analogue of `IsConstLocal` just above, kept as its own separate
||| type rather than widening `IsConstLocal` itself: `boxedConstConExpr`
||| only ever handles `RCConstCon`, so adding a `RCConstClosure` case
||| to `IsConstLocal` would force a spurious `impossible` arm into code
||| that was never about this shape. `Compiler.RC2.Emit.Util`'s
||| `boxedConstClosureExpr` requires this one instead, for the same
||| coverage-checker reason `IsConstLocal` exists at all.
public export
data IsConstClosureLocal : RCLocal -> Type where
     ItIsConstClosure : IsConstClosureLocal (RCConstClosure n missing)

||| Witness that `l` is one of `RCLocal`'s five constant forms, never
||| `RCLoc` -- no constructor targets an `RCLoc _` index, so nothing
||| can manufacture this proof for a variable reference. Used
||| wherever a value just needs to be "not a live variable" without
||| narrowing further (`RCConstCon`'s own `args`,
||| `Compiler.RC2.ConstFold`'s `Env`); `constConFieldExpr`
||| (`Compiler.RC2.Emit.Util`) rebuilds the narrower `IsConstLocal` it
||| needs for its own `RCConstCon` case directly, rather than
||| unwrapping one of these.
public export
data IsAnyConstLocal : RCLocal -> Type where
     ItIsNull2        : IsAnyConstLocal RCNull
     ItIsConst2       : IsAnyConstLocal (RCConst c)
     ItIsEmptyCon2    : IsAnyConstLocal (RCEmptyCon n ci i)
     ItIsConstCon2    : IsAnyConstLocal (RCConstCon n ci t args)
     ItIsConstClosure2 : IsAnyConstLocal (RCConstClosure n missing)

export
covering
Eq RCLocal where
  (RCLoc i1) == (RCLoc i2) = i1 == i2
  RCNull == RCNull = True
  (RCConst c1) == (RCConst c2) = c1 == c2
  (RCEmptyCon n1 _ t1) == (RCEmptyCon n2 _ t2) = n1 == n2 && t1 == t2
  (RCConstCon n1 _ t1 a1) == (RCConstCon n2 _ t2 a2) = n1 == n2 && t1 == t2 && a1 == a2
  (RCConstClosure n1 m1) == (RCConstClosure n2 m2) = n1 == n2 && m1 == m2
  _ == _ = False

export
covering
Ord RCLocal where
  compare l1 l2 = compare (tagOf l1) (tagOf l2) <+> sameCtor l1 l2
    where
      tagOf : RCLocal -> Int
      tagOf (RCLoc _)          = 0
      tagOf RCNull             = 1
      tagOf (RCConst _)        = 2
      tagOf (RCEmptyCon {})    = 3
      tagOf (RCConstCon {})    = 4
      tagOf (RCConstClosure {}) = 5

      -- `tagOf` above already orders any differing pair of
      -- constructors; every case reachable here has l1/l2 as the same
      -- constructor, so the catch-all is dead code, only there to
      -- satisfy coverage.
      sameCtor : RCLocal -> RCLocal -> Ordering
      sameCtor (RCLoc i1)   (RCLoc i2)   = compare i1 i2
      sameCtor RCNull       RCNull       = EQ
      sameCtor (RCConst c1) (RCConst c2) = compare c1 c2
      sameCtor (RCEmptyCon n1 _ t1) (RCEmptyCon n2 _ t2) =
        compare n1 n2 <+> compare t1 t2
      sameCtor (RCConstCon n1 _ t1 a1) (RCConstCon n2 _ t2 a2) =
        compare n1 n2 <+> compare t1 t2 <+> compare a1 a2
      sameCtor (RCConstClosure n1 m1) (RCConstClosure n2 m2) =
        compare n1 n2 <+> compare m1 m2
      sameCtor _ _ = EQ

export
covering
Show RCLocal where
  show (RCLoc i) = "v" ++ show i
  show RCNull = "[__]"
  show (RCConst c) = "#" ++ show c
  show (RCEmptyCon n _ t) = "#" ++ show n ++ "@" ++ show t
  show (RCConstCon n _ t args) = "#" ++ show n ++ "@" ++ show t ++ "(" ++ show args ++ ")"
  show (RCConstClosure n m) = "#" ++ show n ++ "/" ++ show m ++ "~closure"

||| The representation decided for an RLet-bound local, carried
||| directly on the RLet node (see `doc/reading-the-ir.md`'s
||| "## 4. Representation" and `doc/native-type-inference.md`).
||| `RInlineNative` is a Phase 2 (`annotate`) refinement of a plain
||| `RNative`: a native op used exactly once, safe to splice inline
||| instead of declaring a C variable -- Phase 1 never produces this
||| directly, only Phase 2 promotes into it. Any Boxed operand the op
||| itself still reads (`ROp.postDrop`, see its own doc comment) rides
||| along with the deferred splice -- `Compiler.RC2.RC`'s own
||| `inlineableRep` doc comment has the full reasoning for why that's
||| still safe.
public export
data Rep = RBoxed | RNative PrimType | RInlineNative PrimType

-- `RCExp`/`RConAlt`/`RConstAlt` are mutually recursive (`RConCase`/
-- `RConstCase` hold `List RConAlt`/`RConstAlt`; both alt types hold a
-- nested `RCExp` in turn) -- forward-declared for the same reason as
-- `RCLocal`/`IsAnyConstLocal` above, rather than one `mutual` block.
data RCExp : Type
data RConAlt : Type
data RConstAlt : Type

public export
data RCExp : Type where
     RV         : FC -> RCLocal -> RCExp
     RAppName   : FC -> (lazy : Maybe LazyReason) -> Name -> List RCLocal -> RCExp
     ||| Direct call to `name`'s dual-ABI worker variant, never valid in
     ||| a closure-building position. Only produced by
     ||| `Compiler.RC2.DualABI`. `postDrop`: see `ROp`'s own doc below.
     ||| See `doc/dual-abi.md`'s Bugs found #3 for the leak this fixed.
     RAppNameRep : FC -> Name -> (argReps : List Rep) -> (retRep : Rep) -> (postDrop : List RCLocal) -> List RCLocal -> RCExp
     ||| Inlined `%foreign` call, splicing `Emit.emitFFIWorker`'s own
     ||| marshalling logic directly at the call site instead of a
     ||| standalone C function. `ccs`/`fargs`/`ret`/`postDrop`/args are
     ||| all inherited verbatim from the `RAppNameRep` this replaces.
     ||| Never valid in a closure-building position. Only produced by
     ||| `Compiler.RC2.DualABI`'s FFI-inline pass.
     RAppFFIInline : FC -> (ccs : List String) -> (fargs : List CFType) -> (ret : CFType)
                  -> (postDrop : List RCLocal) -> List RCLocal -> RCExp
     RUnderApp  : FC -> Name -> (missing : Nat) -> List RCLocal -> RCExp
     RApp       : FC -> (lazy : Maybe LazyReason) -> RCLocal -> RCLocal -> RCExp
     ||| `rep`: this local's representation. See `doc/native-type-inference.md`.
     RLet       : FC -> (var : Int) -> Rep -> RCExp -> RCExp -> RCExp
     ||| `reuseFrom`: if `Just loc`, may reuse `loc`'s storage (an offer
     ||| from an enclosing `RReuseOffer`). Decided by
     ||| `Compiler.RC2.Reuse`, always `Nothing` before it runs. See
     ||| `doc/reuse-analysis.md`.
     RCon       : FC -> Name -> ConInfo -> (tag : Maybe Int) -> List RCLocal -> (reuseFrom : Maybe RCLocal) -> RCExp
     ||| `postDrop`: Boxed operands to drop once read, one entry per
     ||| *occurrence* in `args`. Decided by Phase 2 (`annotate`), always
     ||| `[]` after Phase 1. Canonical explanation every other
     ||| `postDrop` field in this file points back to:
     ||| `doc/native-type-inference.md`'s "What's stored on the IR vs.
     ||| re-derived".
     ROp        : {0 arity : Nat} -> FC -> (lazy : Maybe LazyReason) -> PrimFn arity -> Vect arity RCLocal -> (postDrop : List RCLocal) -> RCExp
     ||| `postDrop` mirrors `ROp`'s own field, primitive-agnostic -- the
     ||| callee's own C implementation is responsible for `dup`-ing
     ||| anything it wants to keep past the call (`support/rc2/ioprims.c`).
     RExtPrim   : FC -> (lazy : Maybe LazyReason) -> Name -> List RCLocal -> (postDrop : List RCLocal) -> RCExp
     ||| Read of one C struct field (`doc/c-struct-support.md`).
     ||| `postDrop` only ever means "drop `structVar`" -- a struct read
     ||| is never `dup`'d.
     RStructGet : FC -> (structVar : RCLocal) -> (structName : String) -> (fieldName : String) -> (postDrop : List RCLocal) -> RCExp
     ||| Write of one C struct field, evaluating to Unit. Same
     ||| reasoning as `RStructGet`.
     RStructSet : FC -> (structVar : RCLocal) -> (structName : String) -> (fieldName : String) -> (value : RCLocal) -> (postDrop : List RCLocal) -> RCExp
     ||| A comparison fused into a two-way branch with no Bool ever
     ||| materialised. Only produced by Phase 1's `tryFuseCompare` --
     ||| see `doc/native-type-inference.md`'s "Comparisons are a
     ||| separate, narrower mechanism". `postDrop` mirrors `ROp`'s own field.
     RCmpCase   : FC -> PrimFn 2 -> Vect 2 RCLocal -> (postDrop : List RCLocal) -> (whenTrue : RCExp) -> (whenFalse : RCExp) -> RCExp
     RConCase   : FC -> RCLocal -> List RConAlt -> Maybe RCExp -> RCExp
     RConstCase : FC -> RCLocal -> List RConstAlt -> Maybe RCExp -> RCExp
     RPrimVal   : FC -> Constant -> RCExp
     RErased    : FC -> RCExp
     RCrash     : FC -> String -> RCExp
     ||| Increment `loc`'s refcount by `S extra` (`extra=0`: one
     ||| increment), then continue -- what a borrowed use lowers to.
     ||| `S extra`, not a plain `Nat`, makes a no-op `RDup`
     ||| unrepresentable at the type level. Every construction site as
     ||| of this commit passes `extra = 0`; a future pass batches
     ||| several increments into one `extra > 0` call.
     RDup       : FC -> RCLocal -> (extra : Nat) -> RCExp -> RCExp
     ||| Cleanup of owned variables dead at this point. Lowers to
     ||| `idris2rc2_drop` calls, except any folded into a reuse slot instead.
     RDrop      : FC -> List RCLocal -> RCExp -> RCExp
     ||| Unconditional, unchecked deallocation of `loc` -- only where
     ||| RC.idr can prove it's a brand-new, never-shared allocation.
     RFree      : FC -> RCLocal -> RCExp -> RCExp
     ||| Releases an `RReuseOffer` not consumed by any `RCon` on this
     ||| path. Lowers to `idris2rc2_dropReuseConstructor`. See `doc/reuse-analysis.md`.
     RReleaseReuse : FC -> RCLocal -> RCExp -> RCExp
     ||| Explicit tail-recursive loop. `loopParams`: this loop's carried
     ||| locals; `initial`: their starting values; `body` runs
     ||| repeatedly until an `RLoopContinue` starts the next iteration
     ||| or anything else exits. `prologueDrop`: top-level args dead in
     ||| Boxed form once their native shadow is declared. Only produced
     ||| by `Compiler.RC2.Loop`'s `applyLoop` -- see `doc/loop-conversion.md`.
     RLoop : FC -> (loopParams : List (Int, Rep)) -> (initial : List RCLocal) -> (prologueDrop : List RCLocal) -> RCExp -> RCExp
     ||| Continue the nearest enclosing `RLoop` with `args` as each loop
     ||| param's new value (ownership already decided by Phase 2,
     ||| unchanged here). `postDrop` decided separately by `applyLoop`
     ||| once each param's final `Rep` is known -- see
     ||| `doc/loop-conversion.md`'s "Bugs found and fixed" #5.
     RLoopContinue : FC -> List RCLocal -> (postDrop : List RCLocal) -> RCExp
     ||| Runtime uniqueness check for whether `sc`'s storage can be
     ||| reused by a later same-shape `RCon`: if unique, its storage is
     ||| reserved; otherwise every `dupOnShared` entry is `dup`'d before
     ||| `sc` drops normally. `dropOnUnique`: fields needing an explicit
     ||| drop only on the unique path, where `sc` itself isn't dropped.
     ||| Only inserted by `Compiler.RC2.Reuse`'s `resolveAlt` -- see
     ||| `doc/reuse-analysis.md`.
     RReuseOffer : FC -> (sc : RCLocal) -> (dupOnShared : List RCLocal) -> (dropOnUnique : List RCLocal) -> RCExp -> RCExp

public export
data RConAlt : Type where
     MkRConAlt : Name -> ConInfo -> (tag : Maybe Int) -> (args : List Int) -> RCExp -> RConAlt

public export
data RConstAlt : Type where
     MkRConstAlt : Constant -> RCExp -> RConstAlt

||| `MkRCFun`'s own top-level parameters/`retRep`: the dual (Boxed/
||| native) calling convention foundation (`doc/dual-abi.md`).
||| `isWorker` marks a `Compiler.RC2.DualABI`-synthesized worker,
||| reachable only through a direct `RAppNameRep` call, never stored in
||| a `Closure`/dispatched via `idris2rc2_dispatchClosure` -- decides
||| `Compiler.RC2.Emit`'s `createCFunctions`'s own C declaration shape.
||| `False` for every ordinary function and dual-ABI wrapper.
public export
data RCDef : Type where
     MkRCFun : (args : List (Int, Rep)) -> (retRep : Rep) -> (isWorker : Bool) -> RCExp -> RCDef
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
freeLocalsR (RExtPrim _ _ _ args _) = fromList args
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
freeLocalsR (RDup _ v _ body) = insert v (freeLocalsR body)
freeLocalsR (RDrop _ vars body) = union (fromList vars) (freeLocalsR body)
freeLocalsR (RFree _ v body) = insert v (freeLocalsR body)
freeLocalsR (RReleaseReuse _ v body) = insert v (freeLocalsR body)
freeLocalsR (RReuseOffer _ sc dupOnShared dropOnUnique body) =
    union (insert sc (fromList dupOnShared `union` fromList dropOnUnique)) (freeLocalsR body)
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
countUsesR l (RExtPrim _ _ _ args _) = length (filter (== l) args)
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
countUsesR l (RDup _ v extra body) = (if v == l then S extra else 0) + countUsesR l body
countUsesR l (RDrop _ vars body) = length (filter (== l) vars) + countUsesR l body
countUsesR l (RFree _ v body) = (if v == l then 1 else 0) + countUsesR l body
countUsesR l (RReleaseReuse _ v body) = (if v == l then 1 else 0) + countUsesR l body
countUsesR l (RReuseOffer _ sc dupOnShared dropOnUnique body) =
    (if sc == l then 1 else 0) + length (filter (== l) dupOnShared)
    + length (filter (== l) dropOnUnique) + countUsesR l body
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
usedConstructorsR (RDup _ _ _ body) = usedConstructorsR body
usedConstructorsR (RDrop _ _ body) = usedConstructorsR body
usedConstructorsR (RFree _ _ body) = usedConstructorsR body
usedConstructorsR (RReleaseReuse _ _ body) = usedConstructorsR body
usedConstructorsR (RReuseOffer _ _ _ _ body) = usedConstructorsR body
usedConstructorsR _ = empty

------------------------------------------------------------------------
-- Generic `Name`-collecting fold
--
-- `Compiler.RC2.DeadCode`'s reachability walk and
-- `Compiler.RC2.Emit.ExternRefs`'s two forward-declaration walks are
-- the same exhaustive `RCExp`/`RCLocal` recursion, differing only in
-- which name-bearing nodes they care about. That recursion is written
-- once here so a new `RCExp`/`RCLocal` constructor forces a single
-- update rather than three. `freeLocalsR`/`countUsesR`/
-- `usedConstructorsR` above stay separate on purpose: they collect
-- `RCLocal`s / use counts / *constructor* names, a different question
-- with a different accumulator, not a `Name`-set the callbacks below
-- could express.

||| What a name-bearing `RCExp`/`RCLocal` node contributes to a
||| `foldRCNamesR` pass -- each field answers "given this name (and,
||| for a call, its arguments), what does it add to the result", and
||| the fold supplies every bit of the structural recursion.
public export
record RCNameFold m where
  constructor MkRCNameFold
  ||| `RAppName` -- a saturated direct call. `args` in full so a caller
  ||| can take `length args` for the arity.
  onAppName : Name -> List RCLocal -> m
  ||| `RAppNameRep` -- a dual-ABI worker call.
  onAppNameRep : Name -> m
  ||| `RUnderApp` -- a partial-application closure build.
  onUnderApp : Name -> m
  ||| `RCon` (dynamic) and `RCConstCon` (`ConstFold`-folded literal) --
  ||| `tag` distinguishes the untagged ones that carry a runtime
  ||| `->name` string.
  onCon : Name -> (tag : Maybe Int) -> m
  ||| `RCConstClosure` -- a `ConstFold`-folded zero-capture closure.
  onConstClosure : Name -> m

||| An `RCNameFold` contributing nothing anywhere -- start from this
||| and override only the fields a given walker cares about (record
||| update syntax: `{ onAppName := ... } noRCNames`).
public export
noRCNames : Monoid m => RCNameFold m
noRCNames = MkRCNameFold (\_,_ => neutral) (\_ => neutral) (\_ => neutral)
                         (\_,_ => neutral) (\_ => neutral)

export
foldRCNamesL : Monoid m => RCNameFold m -> RCLocal -> m
foldRCNamesL nf (RCConstClosure n _)      = nf.onConstClosure n
foldRCNamesL nf (RCConstCon n _ tag args) = nf.onCon n tag <+> concatMap (foldRCNamesL nf) args
foldRCNamesL _  (RCLoc _)                 = neutral
foldRCNamesL _  RCNull                    = neutral
foldRCNamesL _  (RCConst _)               = neutral
foldRCNamesL _  (RCEmptyCon {})           = neutral

export
foldRCNamesR : Monoid m => RCNameFold m -> RCExp -> m
foldRCNamesR nf = go
  where
    l : RCLocal -> m
    l = foldRCNamesL nf

    ls : List RCLocal -> m
    ls = concatMap l

    go : RCExp -> m
    go (RV _ x) = l x
    go (RAppName _ _ n args) = nf.onAppName n args <+> ls args
    go (RAppNameRep _ n _ _ postDrop args) = nf.onAppNameRep n <+> ls postDrop <+> ls args
    go (RAppFFIInline _ _ _ _ postDrop args) = ls postDrop <+> ls args
    go (RUnderApp _ n _ args) = nf.onUnderApp n <+> ls args
    go (RApp _ _ c a) = l c <+> l a
    go (RLet _ _ _ value body) = go value <+> go body
    go (RCon _ n _ tag args reuseFrom) = nf.onCon n tag <+> ls args <+> maybe neutral l reuseFrom
    go (ROp _ _ _ args postDrop) = ls (toList args) <+> ls postDrop
    go (RExtPrim _ _ _ args postDrop) = ls args <+> ls postDrop
    go (RStructGet _ structVar _ _ postDrop) = l structVar <+> ls postDrop
    go (RStructSet _ structVar _ _ value postDrop) = l structVar <+> l value <+> ls postDrop
    go (RCmpCase _ _ args postDrop whenTrue whenFalse) =
        ls (toList args) <+> ls postDrop <+> go whenTrue <+> go whenFalse
    go (RConCase _ sc alts mDef) =
        l sc <+> concatMap (\(MkRConAlt _ _ _ _ body) => go body) alts <+> maybe neutral go mDef
    go (RConstCase _ sc alts mDef) =
        l sc <+> concatMap (\(MkRConstAlt _ body) => go body) alts <+> maybe neutral go mDef
    go (RPrimVal _ _) = neutral
    go (RErased _) = neutral
    go (RCrash _ _) = neutral
    go (RDup _ v _ body) = l v <+> go body
    go (RDrop _ vars body) = ls vars <+> go body
    go (RFree _ v body) = l v <+> go body
    go (RReleaseReuse _ v body) = l v <+> go body
    go (RLoop _ _ initial prologueDrop body) = ls initial <+> ls prologueDrop <+> go body
    go (RLoopContinue _ args postDrop) = ls args <+> ls postDrop
    go (RReuseOffer _ sc dupOnShared dropOnUnique body) =
        l sc <+> ls dupOnShared <+> ls dropOnUnique <+> go body

||| `foldRCNamesR` lifted over a whole `RCDef` (only `MkRCFun`/
||| `MkRCError` carry an `RCExp` body).
export
foldRCNamesD : Monoid m => RCNameFold m -> RCDef -> m
foldRCNamesD nf (MkRCFun _ _ _ body) = foldRCNamesR nf body
foldRCNamesD nf (MkRCError body)     = foldRCNamesR nf body
foldRCNamesD _  (MkRCCon _ _ _)      = neutral
foldRCNamesD _  (MkRCForeign _ _ _)  = neutral
