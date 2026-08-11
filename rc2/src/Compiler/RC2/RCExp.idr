module Compiler.RC2.RCExp

-- The reference-counted IR produced directly from Compiler.LambdaLift's
-- `Lifted` (NOT from Compiler.ANF -- rc2 implements its own ANF-style
-- normalisation as part of building this IR, see Compiler.RC2.RC).
--
-- Every AVar-equivalent *use* (RCVar) already carries the ownership
-- decision RC.idr made at that specific occurrence (owned/move vs
-- borrowed/dup), and every point where a dead owned variable needs cleanup
-- is already an explicit `RDrop` node. Compiler.RC2.Emit is a purely
-- mechanical RCExp -> C lowering: it makes no ownership decisions of its
-- own.
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

||| A use of a local, annotated with the ownership decision RC.idr made at
||| that specific occurrence.
public export
record RCVar where
  constructor MkRCVar
  rcVar     : RCLocal
  ||| True: this occurrence is a borrow -- Emit must dup it before use.
  ||| False: this occurrence owns the value -- Emit uses it directly (move).
  borrowed  : Bool

||| The representation Compiler.RC2.RC decided for an RLet-bound local,
||| computed during the Lifted -> RCExp conversion itself (see RC.idr's
||| `repOf`) and carried directly on the RLet node -- not a side table
||| Emit has to (re)compute or look up separately.
public export
data Rep = RBoxed | RNative PrimType

mutual
  public export
  data RCExp : Type where
       RV         : FC -> RCVar -> RCExp
       RAppName   : FC -> (lazy : Maybe LazyReason) -> Name -> List RCVar -> RCExp
       RUnderApp  : FC -> Name -> (missing : Nat) -> List RCVar -> RCExp
       RApp       : FC -> (lazy : Maybe LazyReason) -> RCVar -> RCVar -> RCExp
       ||| `rep`: the native-or-boxed representation decided for this local
       ||| (see `Rep`). `dropIfUnused`: True when the bound variable is dead
       ||| on arrival (never used in `body`) and so must be dropped
       ||| immediately after being bound (meaningless when `rep` is
       ||| `RNative _`: native locals are never refcounted).
       RLet       : FC -> (var : Int) -> Rep -> RCExp -> RCExp -> (dropIfUnused : Bool) -> RCExp
       RCon       : FC -> Name -> ConInfo -> (tag : Maybe Int) -> List RCVar -> RCExp
       ROp        : {0 arity : Nat} -> FC -> (lazy : Maybe LazyReason) -> PrimFn arity -> Vect arity RCVar -> RCExp
       RExtPrim   : FC -> (lazy : Maybe LazyReason) -> Name -> List RCLocal -> RCExp
       RConCase   : FC -> RCLocal -> List RConAlt -> Maybe RCExp -> RCExp
       RConstCase : FC -> RCLocal -> List RConstAlt -> Maybe RCExp -> RCExp
       RPrimVal   : FC -> Constant -> RCExp
       RErased    : FC -> RCExp
       RCrash     : FC -> String -> RCExp
       ||| Explicit cleanup of owned variables that are dead at this point,
       ||| wrapping the rest of the computation. Emit lowers each of these
       ||| to `idris2rc2_drop(...)` calls, except for any it decides to
       ||| fold into a constructor-reuse slot instead (see module note).
       RDrop      : FC -> List RCLocal -> RCExp -> RCExp

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
freeLocalsR (RV _ v) = singleton v.rcVar
freeLocalsR (RAppName _ _ _ args) = fromList (map rcVar args)
freeLocalsR (RUnderApp _ _ _ args) = fromList (map rcVar args)
freeLocalsR (RApp _ _ c a) = fromList [c.rcVar, a.rcVar]
freeLocalsR (RLet _ var _ value body _) =
    union (freeLocalsR value) (delete (RCLoc var) (freeLocalsR body))
freeLocalsR (RCon _ _ _ _ args) = fromList (map rcVar args)
freeLocalsR (ROp _ _ _ args) = fromList (toList (map rcVar args))
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
freeLocalsR (RDrop _ vars body) = union (fromList vars) (freeLocalsR body)
freeLocalsR _ = empty

export
usedConstructorsR : RCExp -> SortedSet Name
usedConstructorsR (RLet _ _ _ value body _) = union (usedConstructorsR value) (usedConstructorsR body)
usedConstructorsR (RCon _ n _ _ _) = singleton n
usedConstructorsR (RConCase _ _ alts mDef) =
    let altsCons = map (\(MkRConAlt _ _ _ _ body) => usedConstructorsR body) alts
    in concat (maybe altsCons (\d => usedConstructorsR d :: altsCons) mDef)
usedConstructorsR (RConstCase _ _ alts mDef) =
    let altsCons = map (\(MkRConstAlt _ body) => usedConstructorsR body) alts
    in concat (maybe altsCons (\d => usedConstructorsR d :: altsCons) mDef)
usedConstructorsR (RDrop _ _ body) = usedConstructorsR body
usedConstructorsR _ = empty
