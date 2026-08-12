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
-- constructor/op argument) is used *as-is*, with no per-use annotation:
-- any refcount adjustment it needs has already been made explicit as a
-- wrapping RDup/RDrop/RFree node earlier in the tree. Compiler.RC2.Emit is
-- a purely mechanical RCExp -> C lowering: it makes no ownership
-- decisions of its own, just lowers each of these three primitives to the
-- matching runtime call.
--
-- (Scope note: the constructor-reuse-in-place optimization -- deciding at
-- runtime whether a dying value's storage can be recycled for a
-- freshly-built constructor of the same shape -- is a distinct, secondary
-- optimization layered on top of plain reference counting. It still lives
-- in Emit for now, driven off of the RDrop lists RC produces; lifting it
-- fully into this IR is future work, not required for the core directive.)

import Core.CompileExpr
import Core.FC
import Core.TT

import Data.SortedSet
import Data.Vect

%default covering

||| A local variable, identified by a compiler-allocated integer id (rc2's
||| own equivalent of Compiler.ANF's AVar -- defined independently here so
||| this whole pipeline has no dependency on Compiler.ANF).
public export
data RCLocal : Type where
     RCLoc  : Int -> RCLocal
     RCNull : RCLocal

export
Eq RCLocal where
  (RCLoc i1) == (RCLoc i2) = i1 == i2
  RCNull == RCNull = True
  _ == _ = False

export
Ord RCLocal where
  compare (RCLoc i1) (RCLoc i2) = compare i1 i2
  compare (RCLoc _) RCNull = GT
  compare RCNull (RCLoc _) = LT
  compare RCNull RCNull = EQ

export
Show RCLocal where
  show (RCLoc i) = "v" ++ show i
  show RCNull = "[__]"

||| The representation Compiler.RC2.RC decided for an RLet-bound local,
||| computed during the Lifted -> RCExp conversion itself (see RC.idr's
||| `repOf`) and carried directly on the RLet node -- not a side table
||| Emit has to (re)compute or look up separately.
public export
data Rep = RBoxed | RNative PrimType

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
       RCon       : FC -> Name -> ConInfo -> (tag : Maybe Int) -> List RCLocal -> RCExp
       ROp        : {0 arity : Nat} -> FC -> (lazy : Maybe LazyReason) -> PrimFn arity -> Vect arity RCLocal -> RCExp
       RExtPrim   : FC -> (lazy : Maybe LazyReason) -> Name -> List RCLocal -> RCExp
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

  public export
  data RConAlt : Type where
       MkRConAlt : Name -> ConInfo -> (tag : Maybe Int) -> (args : List Int) -> RCExp -> RConAlt

  public export
  data RConstAlt : Type where
       MkRConstAlt : Constant -> RCExp -> RConstAlt

public export
data RCDef : Type where
     MkRCFun : (args : List Int) -> RCExp -> RCDef
     MkRCCon : (tag : Maybe Int) -> (arity : Nat) -> (nt : Maybe Nat) -> RCDef
     MkRCForeign : (ccs : List String) -> (fargs : List CFType) -> CFType -> RCDef
     MkRCError : RCExp -> RCDef

------------------------------------------------------------------------
-- Structural analyses used by both RC.idr (ownership annotation) and
-- Emit.idr (constructor-reuse bookkeeping).

export
freeLocalsR : RCExp -> SortedSet RCLocal
freeLocalsR (RV _ v) = singleton v
freeLocalsR (RAppName _ _ _ args) = fromList args
freeLocalsR (RUnderApp _ _ _ args) = fromList args
freeLocalsR (RApp _ _ c a) = fromList [c, a]
freeLocalsR (RLet _ var _ value body) =
    union (freeLocalsR value) (delete (RCLoc var) (freeLocalsR body))
freeLocalsR (RCon _ _ _ _ args) = fromList args
freeLocalsR (ROp _ _ _ args) = fromList (toList args)
freeLocalsR (RExtPrim _ _ _ args) = fromList args
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
freeLocalsR _ = empty

export
usedConstructorsR : RCExp -> SortedSet Name
usedConstructorsR (RLet _ _ _ value body) = union (usedConstructorsR value) (usedConstructorsR body)
usedConstructorsR (RCon _ n _ _ _) = singleton n
usedConstructorsR (RConCase _ _ alts mDef) =
    let altsCons = map (\(MkRConAlt _ _ _ _ body) => usedConstructorsR body) alts
    in concat (maybe altsCons (\d => usedConstructorsR d :: altsCons) mDef)
usedConstructorsR (RConstCase _ _ alts mDef) =
    let altsCons = map (\(MkRConstAlt _ body) => usedConstructorsR body) alts
    in concat (maybe altsCons (\d => usedConstructorsR d :: altsCons) mDef)
usedConstructorsR (RDup _ _ body) = usedConstructorsR body
usedConstructorsR (RDrop _ _ body) = usedConstructorsR body
usedConstructorsR (RFree _ _ body) = usedConstructorsR body
usedConstructorsR _ = empty
