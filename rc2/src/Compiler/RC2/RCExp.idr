module Compiler.RC2.RCExp

-- The reference-counted IR produced directly from Compiler.LambdaLift's
-- `Lifted` (NOT from Compiler.ANF -- rc2 implements its own ANF-style
-- normalisation as part of building this IR, see Compiler.RC2.RC).
--
-- Reference counting is fully explicit, as three primitive node types
-- Compiler.RC2.RC inserts during the Lifted -> RCExp conversion itself
-- (not a separate pass, and not implicit flags on variable uses) -- which
-- makes each one an independently visible, independently optimisable
-- operation:
--   * `RDup`  : increment a value's refcount ("add").
--   * `RDrop` : decrement a value's refcount, recursively freeing it (and
--               its children) once it reaches zero.
--   * `RFree` : unconditionally deallocate a value *now*, with no refcount
--               check at all. Only ever inserted where RC.idr can prove,
--               from the shape of the binding alone, that the value is a
--               brand-new heap allocation that has had no chance to be
--               shared (see RC.idr's `freeableShape`) -- e.g. a
--               constructor built and immediately found dead. Using this
--               instead of a checked `RDrop` skips a branch and a memory
--               read; it is unsound to insert anywhere the value's
--               provenance isn't statically known this precisely (it may
--               be a shared/immortal predefined value).
-- Every local variable reference (RV, and every RCLocal used as a call/
-- constructor argument) is used *as-is*, with no per-use annotation: any
-- refcount adjustment it needs has already been made explicit as a
-- wrapping RDup/RDrop/RFree node earlier in the tree. An `ROp`'s operands
-- are the one place a use *does* carry an annotation of its own --
-- `postDrop`, see its own doc comment -- since an op reads its operands
-- and produces a brand-new value in the same breath, with no separate
-- "moment" to wrap an RDrop node around the read the way RLet/RConCase
-- bodies have. Compiler.RC2.Emit is a purely mechanical RCExp -> C
-- lowering: it makes no ownership decisions of its own, just lowers each
-- of RDup/RDrop/RFree/postDrop to the matching runtime call.
--
-- (Scope note: the constructor-reuse-in-place optimization -- deciding at
-- runtime whether a dying value's storage can be recycled for a
-- freshly-built constructor of the same shape -- is a distinct, secondary
-- optimization layered on top of plain reference counting. It's decided
-- by Compiler.RC2.Reuse, a dedicated pass run after Compiler.RC2.RC's
-- normalize+annotate are both done, and encoded directly on this IR
-- (RCon's `reuseFrom`, and the `RReuseOffer`/`RReleaseReuse` nodes
-- below) -- Compiler.RC2.Emit only ever lowers it, same as
-- everything else in this tree; see Compiler.RC2.Reuse's own module
-- note for the full protocol.)

import Core.CompileExpr
import Core.FC
import Core.TT

import Data.SortedSet
import Data.Vect

%default covering

||| A local variable, identified by a compiler-allocated integer id (rc2's
||| own equivalent of Compiler.ANF's AVar -- defined independently here so
||| this whole pipeline has no dependency on Compiler.ANF). `RCConst`
||| carries a native-eligible literal directly -- Compiler.RC2.RC's
||| Phase 1 (`bindOne`) produces this instead of allocating an id and
||| wrapping an RLet around an RPrimVal for such a literal (see its own
||| comment), since there both is and never was any real local variable
||| there to name: nothing to own, dup, drop, or free, no RepMap entry,
||| no C declaration -- Compiler.RC2.Emit renders it as an inline literal
||| expression wherever it's read (repOfLocal/inlineExprFor). Anywhere
||| that pattern-matches on RCLocal to reason about ownership (Owned
||| sets, `natives`, RDup/RDrop/RFree targets) must treat RCConst like a
||| native local -- excluded, never touched -- see RC.idr's
||| `splitBorrows`.
|||
||| `RCEmptyCon` is the same idea applied to a zero-argument, *tagged*
||| data constructor other than `Nil`/`Nothing`/`Z`/`MkUnit` (those four
||| keep going through the ordinary RCon -> RLet path unchanged, since
||| Compiler.RC2.Emit already renders them as a bare C `NULL` at
||| construction and matches them by NULL-vs-non-NULL -- see its
||| `emitRC`'s RCon/RConCase cases -- and `bindOne` maps them directly to
||| `RCNull` instead, reusing that existing representation rather than
||| this one). Every *other* nullary tagged constructor construction
||| (`f Red`, `MkFoo True Nothing`, ...) needs no heap allocation either
||| -- there's nothing to store, only a tag to remember -- so
||| Compiler.RC2.RC's Phase 1 (`bindOne`) produces this directly instead
||| of an RLet+RCon, the same way it does for RCConst; Compiler.RC2.Emit
||| renders it inline as a tagged-pointer constant expression
||| (`varName`) with no C declaration. Untagged nullary constructors
||| (matched by name, not by tag -- rare) aren't covered and still go
||| through the general RCon path. Treated identically to RCConst for
||| ownership purposes everywhere RCConst is excluded (RC.idr's
||| `splitBorrows`/`isBoxedOperand`).
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

||| The representation Compiler.RC2.RC decided for an RLet-bound local,
||| computed during the Lifted -> RCExp conversion itself (see RC.idr's
||| `repOf`) and carried directly on the RLet node -- not a side table
||| Emit has to (re)compute or look up separately.
|||
||| `RInlineNative` is a refinement `RC.idr`'s Phase 2 (`annotate`) can
||| promote a plain `RNative` to, once ownership is known: it means this
||| local's value is a native op with no Boxed operands at all
||| (`ROp.postDrop == []`), referenced exactly once in the rest of the
||| function -- safe and free to splice its expression directly into
||| that one use site instead of ever declaring a C variable for it at
||| all (see Emit.idr's `InlineMap`/`(RInlineNative ty, _)` RLet case).
||| Phase 1 never produces this directly (it doesn't know postDrop or
||| use-counts yet); only Phase 2 ever promotes into it.
public export
data Rep = RBoxed | RNative PrimType | RInlineNative PrimType

mutual
  public export
  data RCExp : Type where
       RV         : FC -> RCLocal -> RCExp
       RAppName   : FC -> (lazy : Maybe LazyReason) -> Name -> List RCLocal -> RCExp
       RUnderApp  : FC -> Name -> (missing : Nat) -> List RCLocal -> RCExp
       RApp       : FC -> (lazy : Maybe LazyReason) -> RCLocal -> RCLocal -> RCExp
       ||| `rep`: the native-or-boxed representation decided for this local
       ||| (see `Rep`). If the bound variable turns out dead on arrival
       ||| (never used in `body`), RC.idr wraps `body` in an RDrop/RFree
       ||| for it directly -- there is no separate flag for that case, it
       ||| is just the same cleanup primitive as everywhere else.
       RLet       : FC -> (var : Int) -> Rep -> RCExp -> RCExp -> RCExp
       ||| `reuseFrom`: if `Just loc`, this constructor's allocation may
       ||| reuse `loc`'s storage in place (`loc` is a dying constructor
       ||| of the exact same shape -- same field count -- offered by an
       ||| enclosing `RReuseOffer`, see its own doc comment).
       ||| Decided by Compiler.RC2.Reuse's `resolveReuse`, a dedicated
       ||| pass that runs on the fully Phase-1+2'd tree, after
       ||| Compiler.RC2.RC's normalize+annotate and before
       ||| Compiler.RC2.Emit -- not by RC.idr itself. Phase 1/2 always
       ||| leave this `Nothing`.
       RCon       : FC -> Name -> ConInfo -> (tag : Maybe Int) -> List RCLocal -> (reuseFrom : Maybe RCLocal) -> RCExp
       ||| `postDrop`: every Boxed operand this op needs dropped once
       ||| it's done reading it (one entry per *occurrence* in `args`,
       ||| so an operand read twice, e.g. `x + x`, appears twice) --
       ||| decided by Compiler.RC2.RC's `annotate` (Phase 2) exactly
       ||| like an RLet's `Rep`, and carried directly on the node so
       ||| Emit.idr only ever lowers it, the same way it lowers
       ||| RDup/RDrop/RFree, rather than independently re-deriving
       ||| "which of my operands are Boxed" at emission time (which it
       ||| used to do, and which was the one place Emit wasn't purely
       ||| mechanical -- see the module note above). Phase 1
       ||| (`normalize`) always constructs this as `[]`; only Phase 2
       ||| ever fills it in.
       ROp        : {0 arity : Nat} -> FC -> (lazy : Maybe LazyReason) -> PrimFn arity -> Vect arity RCLocal -> (postDrop : List RCLocal) -> RCExp
       RExtPrim   : FC -> (lazy : Maybe LazyReason) -> Name -> List RCLocal -> RCExp
       ||| A boolean comparison (LT/GT/EQ/LTE/GTE) fused directly into a
       ||| two-way branch: `whenTrue`/`whenFalse` are taken according to
       ||| the comparison's own result, with the Bool it would otherwise
       ||| produce never materialised as a value at all (no heap
       ||| allocation, no case-scrutinee variable). Only ever produced by
       ||| Compiler.RC2.RC's Phase 1 `normalize`, when a comparison op is
       ||| the sole, immediate scrutinee of a two-way match on Idris2's
       ||| own Bool encoding (False=0/True=1) -- see `normalize`'s own
       ||| `tryFuseCompare`. `postDrop` mirrors ROp's own field (see its
       ||| doc comment): the comparison reads its operands and
       ||| immediately branches, with no separate "moment" a wrapping
       ||| RDrop could target either -- Phase 1 always constructs this as
       ||| `[]`, only Phase 2 (`annotate`) fills it in.
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
       ||| Release a reuse candidate (see `RReuseOffer`) that
       ||| turned out *not* to be consumed by any RCon on this
       ||| particular execution path (a sibling branch's RCon claimed it
       ||| instead, or no matching RCon was reachable on this path at
       ||| all) -- lowers to `idris2rc2_dropReuseConstructor(loc)`, which
       ||| is a no-op if the runtime uniqueness check that created this
       ||| offer failed (so `loc` was already dropped normally there and
       ||| ends up NULL here) and a real release otherwise. Only ever
       ||| inserted by Compiler.RC2.Reuse, never by RC.idr.
       RReleaseReuse : FC -> RCLocal -> RCExp -> RCExp
       ||| A tail call to *this same function*, with `args` as the new
       ||| argument values -- compiled to reassigning the function's own
       ||| parameter variables and jumping back to the top (a `goto`) in
       ||| Compiler.RC2.Emit, instead of building a closure and going
       ||| through the generic boxed trampoline. Only ever produced by
       ||| Compiler.RC2.Loop, a dedicated pass that runs on the fully
       ||| Phase-1+2'd and Reuse'd tree (mirroring Compiler.RC2.Reuse's
       ||| own place in the pipeline): it walks *only* a function's own
       ||| tail positions (the same set Compiler.RC2.Emit's
       ||| TailPositionStatus threading already visits structurally --
       ||| RLet's body, RDup/RDrop/RFree/RReleaseReuse's continuation,
       ||| RCmpCase's two branches, RConCase/RConstCase's alts and
       ||| default) looking for a plain `RAppName` (no `lazy` reason)
       ||| whose target is this very function, and replaces each one
       ||| found with this node. Ownership is untouched by this
       ||| replacement -- `annotate` (Phase 2) already computed the
       ||| right dup/move decisions for that `RAppName`'s own arguments
       ||| before Loop ever ran, exactly as it would for a call to any
       ||| other function, and those decisions are preserved as-is (any
       ||| wrapping RDup/RDrop/RFree stays put; only the terminal
       ||| RAppName node itself is swapped). RC.idr's own Phase 1/2 never
       ||| produce this.
       ||| A runtime uniqueness check deciding whether `sc`'s own storage
       ||| can be repurposed in place for a later `RCon` of the same
       ||| shape (see `RCon`'s own `reuseFrom`) instead of allocating
       ||| fresh and dropping `sc` normally: if `sc` turns out unique,
       ||| its storage is reserved for that reuse; otherwise, every
       ||| entry in `dupOnShared` is dup'd (they were destructured
       ||| straight out of `sc`'s own storage -- plain pointer aliasing,
       ||| see `RConAlt`'s own former doc comment -- so anything that
       ||| survives past this point needs its own reference before `sc`'s
       ||| ordinary recursive drop potentially frees them out from under
       ||| it) and `sc` is dropped normally. Either way, execution
       ||| continues into the same `body` afterward -- this is a setup
       ||| step with two ways of getting there, not a real two-armed
       ||| branch the way `RCmpCase`/`RConCase` are.
       |||
       ||| Only ever inserted by Compiler.RC2.Reuse's `resolveAlt`,
       ||| wrapping (a prefix of) whatever an eligible `RConAlt`'s own
       ||| body already was -- see its module note for the full
       ||| eligibility protocol (mirrors the old `RConAlt.offersReuse`
       ||| flag this node replaces: an alt "offers reuse" exactly when
       ||| its own body's leading shape, after any ordinary drops, is
       ||| this node). Exactly one `RCon` reachable from `body` (per
       ||| execution path) ends up with `reuseFrom = Just sc`; every
       ||| path that doesn't reach one gets an explicit
       ||| `RReleaseReuse sc` instead, so the reservation is never
       ||| simply lost. RC.idr's own Phase 1/2 never produce this.
       RReuseOffer : FC -> (sc : RCLocal) -> (dupOnShared : List RCLocal) -> RCExp -> RCExp
       RSelfTailCall : FC -> List RCLocal -> RCExp

  public export
  data RConAlt : Type where
       MkRConAlt : Name -> ConInfo -> (tag : Maybe Int) -> (args : List Int) -> RCExp -> RConAlt

  public export
  data RConstAlt : Type where
       MkRConstAlt : Constant -> RCExp -> RConstAlt

public export
data RCDef : Type where
     ||| `isLoop`: `True` once Compiler.RC2.Loop has found (and rewritten)
     ||| at least one self-tail-call reachable from `body` -- tells
     ||| Compiler.RC2.Emit to wrap the emitted function body in a `goto`
     ||| target (see `RSelfTailCall`'s own doc comment) instead of
     ||| requiring it to re-scan the tree to find out. RC.idr's own
     ||| Phase 1/2 always construct this as `False`; only
     ||| Compiler.RC2.Loop ever sets it.
     MkRCFun : (args : List Int) -> (isLoop : Bool) -> RCExp -> RCDef
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
