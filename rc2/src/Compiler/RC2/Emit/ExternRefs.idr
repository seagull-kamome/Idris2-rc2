||| External-symbol reference walkers for incremental compilation.
||| Two structural folds over `RCExp`/`RCDef` that collect the symbols a
||| translation unit's generated C references but may not itself define
||| -- untagged constructor names (dereferenced as
||| `idris2rc2_constr_<name>`) and directly-called / closure-built
||| function names. `Compiler.RC2.Emit.generateCSourceFile` turns their
||| union over a module's own `defs` into `extern` forward declarations.
||| Non-empty only under incremental compile (`Compiler.RC2.RC2`'s own
||| `incCompile`, where `defs` is a strict subset of the program); a
||| no-op set in whole-program mode, where `collectDeclarations` already
||| forward-declares every referenced symbol from that same `defs` list.
||| Lives here rather than in `Emit.idr` only to keep that module on
||| codegen -- pure analysis, no `Ref`s, nothing emitted.
module Compiler.RC2.Emit.ExternRefs
-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Compiler.RC2.RCExp

import Core.Name

import Data.SortedSet
import Data.Vect

%default covering

||| Every untagged constructor `Name` a def's own generated C
||| dereferences via `->name = idris2rc2_constr_<name>` -- both a
||| dynamic `RCon` construction (`Compiler.RC2.Emit`'s own
||| `createCFunctions` `RCon` case, `when (Nothing == tag) ...`) and a
||| `ConstFold`-folded `RCConstCon` literal
||| (`EmitUtil.boxedConstConExpr`'s own `nameField`) set this field
||| exactly when the constructor's own `tag` is `Nothing`. Whole-program
||| compilation never needs this -- every `MkRCCon` the program could
||| possibly reference already sits in the very same `defs` list
||| `collectDeclarations` forward-declares from -- only matters once a
||| module compiles against a strict subset of the program
||| (`Compiler.RC2.RC2`'s own `incCompile`, see
||| rc2/doc/incremental-compile.md), where the referenced constructor
||| may be owned by a module not present in `defs` at all. Found via a
||| real `--inc rc2` prelude rebuild: `Prelude.Basics` references
||| `Builtin.Void` this way with no declaration anywhere in its own
||| translation unit, a plain "undeclared identifier" C compile error.
||| A fresh, exhaustive walker mirroring `Compiler.RC2.DeadCode`'s own
||| `usedFunctionNamesR`/`usedFunctionNamesL` shape (see that module's
||| own doc comment for why this codebase writes a dedicated walker per
||| concern rather than reusing `RCExp.idr`'s generic ones).
untaggedConstructorRefsL : RCLocal -> SortedSet Name
untaggedConstructorRefsL (RCConstCon n _ Nothing args) = insert n (concatMap untaggedConstructorRefsL args)
untaggedConstructorRefsL (RCConstCon _ _ (Just _) args) = concatMap untaggedConstructorRefsL args
untaggedConstructorRefsL (RCConstClosure _ _) = empty
untaggedConstructorRefsL (RCLoc _) = empty
untaggedConstructorRefsL RCNull = empty
untaggedConstructorRefsL (RCConst _) = empty
untaggedConstructorRefsL (RCEmptyCon {}) = empty

export
untaggedConstructorRefsR : RCExp -> SortedSet Name
untaggedConstructorRefsR (RV _ l) = untaggedConstructorRefsL l
untaggedConstructorRefsR (RAppName _ _ _ args) = concatMap untaggedConstructorRefsL args
untaggedConstructorRefsR (RAppNameRep _ _ _ _ postDrop args) =
    union (concatMap untaggedConstructorRefsL postDrop) (concatMap untaggedConstructorRefsL args)
untaggedConstructorRefsR (RAppFFIInline _ _ _ _ postDrop args) =
    union (concatMap untaggedConstructorRefsL postDrop) (concatMap untaggedConstructorRefsL args)
untaggedConstructorRefsR (RUnderApp _ _ _ args) = concatMap untaggedConstructorRefsL args
untaggedConstructorRefsR (RApp _ _ c a) = union (untaggedConstructorRefsL c) (untaggedConstructorRefsL a)
untaggedConstructorRefsR (RLet _ _ _ value body) = union (untaggedConstructorRefsR value) (untaggedConstructorRefsR body)
untaggedConstructorRefsR (RCon _ n _ Nothing args reuseFrom) =
    insert n (union (concatMap untaggedConstructorRefsL args) (maybe empty untaggedConstructorRefsL reuseFrom))
untaggedConstructorRefsR (RCon _ _ _ (Just _) args reuseFrom) =
    union (concatMap untaggedConstructorRefsL args) (maybe empty untaggedConstructorRefsL reuseFrom)
untaggedConstructorRefsR (ROp _ _ _ args postDrop) =
    union (concatMap untaggedConstructorRefsL (toList args)) (concatMap untaggedConstructorRefsL postDrop)
untaggedConstructorRefsR (RExtPrim _ _ _ args postDrop) =
    union (concatMap untaggedConstructorRefsL args) (concatMap untaggedConstructorRefsL postDrop)
untaggedConstructorRefsR (RStructGet _ structVar _ _ postDrop) =
    union (untaggedConstructorRefsL structVar) (concatMap untaggedConstructorRefsL postDrop)
untaggedConstructorRefsR (RStructSet _ structVar _ _ value postDrop) =
    union (untaggedConstructorRefsL structVar)
          (union (untaggedConstructorRefsL value) (concatMap untaggedConstructorRefsL postDrop))
untaggedConstructorRefsR (RCmpCase _ _ args postDrop t f) =
    union (concatMap untaggedConstructorRefsL (toList args))
          (union (concatMap untaggedConstructorRefsL postDrop)
                 (union (untaggedConstructorRefsR t) (untaggedConstructorRefsR f)))
untaggedConstructorRefsR (RConCase _ sc alts mDef) =
    let altsUsed = map (\(MkRConAlt _ _ _ _ body) => untaggedConstructorRefsR body) alts
    in union (untaggedConstructorRefsL sc) (concat (maybe altsUsed (\d => untaggedConstructorRefsR d :: altsUsed) mDef))
untaggedConstructorRefsR (RConstCase _ sc alts mDef) =
    let altsUsed = map (\(MkRConstAlt _ body) => untaggedConstructorRefsR body) alts
    in union (untaggedConstructorRefsL sc) (concat (maybe altsUsed (\d => untaggedConstructorRefsR d :: altsUsed) mDef))
untaggedConstructorRefsR (RPrimVal _ _) = empty
untaggedConstructorRefsR (RErased _) = empty
untaggedConstructorRefsR (RCrash _ _) = empty
untaggedConstructorRefsR (RDup _ v _ body) = union (untaggedConstructorRefsL v) (untaggedConstructorRefsR body)
untaggedConstructorRefsR (RDrop _ vars body) = union (concatMap untaggedConstructorRefsL vars) (untaggedConstructorRefsR body)
untaggedConstructorRefsR (RFree _ v body) = union (untaggedConstructorRefsL v) (untaggedConstructorRefsR body)
untaggedConstructorRefsR (RReleaseReuse _ v body) = union (untaggedConstructorRefsL v) (untaggedConstructorRefsR body)
untaggedConstructorRefsR (RLoop _ _ initial prologueDrop body) =
    union (concatMap untaggedConstructorRefsL initial)
          (union (concatMap untaggedConstructorRefsL prologueDrop) (untaggedConstructorRefsR body))
untaggedConstructorRefsR (RLoopContinue _ args postDrop) =
    union (concatMap untaggedConstructorRefsL args) (concatMap untaggedConstructorRefsL postDrop)
untaggedConstructorRefsR (RReuseOffer _ sc dupOnShared dropOnUnique body) =
    union (untaggedConstructorRefsL sc)
          (union (concatMap untaggedConstructorRefsL dupOnShared)
                 (union (concatMap untaggedConstructorRefsL dropOnUnique) (untaggedConstructorRefsR body)))

||| Same idea as `untaggedConstructorRefsR`, lifted to a whole `RCDef`.
export
untaggedConstructorRefsD : RCDef -> SortedSet Name
untaggedConstructorRefsD (MkRCFun _ _ _ body) = untaggedConstructorRefsR body
untaggedConstructorRefsD (MkRCCon _ _ _) = empty
untaggedConstructorRefsD (MkRCForeign _ _ _) = empty
untaggedConstructorRefsD (MkRCError body) = untaggedConstructorRefsR body

||| Every function `Name` a def's own generated C references but might
||| not itself define -- a direct call (`RAppName`), a partial-
||| application closure build (`RUnderApp`), or a `ConstFold`-folded
||| zero-capture closure (`RCConstClosure`). Same story as
||| `untaggedConstructorRefsD` above: a no-op set in whole-program mode
||| (`collectDeclarations` already forward-declares every one of these
||| from that very same `defs` list), only populated once `defs` is a
||| single module's own subset (`Compiler.RC2.RC2`'s `incCompile`).
||| Confirmed for real via the same `--inc rc2` prelude rebuild that
||| found `untaggedConstructorRefsD`'s own gap: e.g. `Prelude.Num`
||| calls `Prelude.EqOrd`'s own comparison functions directly by name,
||| with nothing declaring them in `Prelude.Num`'s own translation
||| unit ("implicit declaration of function" C errors).
|||
||| Declared with the exact arity a real `RAppName` call site to it
||| already carries when one exists in `defs` (the true, authoritative
||| arity for a saturated direct call to it -- every plain, non-
||| `RAppNameRep` reference to another module's own top-level function
||| targets that function's Boxed-ABI wrapper entry point specifically:
||| a `RAppNameRep`/native-worker call can only ever target a function
||| `DualABI` proved eligible from *within the same module*
||| (rc2/doc/incremental-compile.md's "Which existing passes need to
||| change"), so it can never appear here -- so the wrapper is always
||| `IDRIS2RC2_Value *(...N boxed pointers...)` shaped, `N` = that call
||| site's own argument count), or arity 0 when it's referenced only as
||| a function-pointer *value* (`RUnderApp`/`RCConstClosure`, never
||| called with a fixed argument list directly) -- both already only
||| ever consumed through an explicit erased-signature cast anyway
||| (`EmitUtil`'s own `(IDRIS2RC2_Value *(*)())` closure-struct field,
||| the exact same cast a *locally*-declared, exact-arity closure
||| target already goes through too), so an arity-0 declaration is
||| harmless there. Trying a single K&R-style (empty-parens, no `void`)
||| declaration for every case first -- relying on it to mean
||| "unspecified arguments" the way traditional C does -- broke on this
||| toolchain's own C standard default (which treats bare `()` as `(void)`,
||| a real difference C23 introduced): a real 2-argument `RAppName`
||| call to a name declared that way is a hard "too many arguments" C
||| error, found the same way as `untaggedConstructorRefsD`'s own gap
||| (a real `--inc rc2` prelude rebuild -- `Prelude.Num` calls
||| `Prelude.EqOrd`'s own comparison functions directly by name).
|||
||| Returns `(Name, Nat)` pairs rather than a `SortedSet`/`SortedMap`
||| directly -- plain list concatenation at every recursive step avoids
||| any merge-order hazard between an arity-bearing `RAppName` sighting
||| and an arity-0 `RUnderApp`/`RCConstClosure` one for the very same
||| name (`generateCSourceFile`'s own call site resolves duplicates
||| with `max`, so whichever order they appear in this list, the real
||| arity always wins over the placeholder 0).
externalFunctionRefsL : RCLocal -> List (Name, Nat)
externalFunctionRefsL (RCConstClosure n _) = [(n, 0)]
externalFunctionRefsL (RCConstCon _ _ _ args) = concatMap externalFunctionRefsL args
externalFunctionRefsL (RCLoc _) = []
externalFunctionRefsL RCNull = []
externalFunctionRefsL (RCConst _) = []
externalFunctionRefsL (RCEmptyCon {}) = []

export
externalFunctionRefsR : RCExp -> List (Name, Nat)
externalFunctionRefsR (RV _ l) = externalFunctionRefsL l
externalFunctionRefsR (RAppName _ _ n args) = (n, length args) :: concatMap externalFunctionRefsL args
externalFunctionRefsR (RAppNameRep _ _ _ _ postDrop args) =
    concatMap externalFunctionRefsL postDrop ++ concatMap externalFunctionRefsL args
externalFunctionRefsR (RAppFFIInline _ _ _ _ postDrop args) =
    concatMap externalFunctionRefsL postDrop ++ concatMap externalFunctionRefsL args
externalFunctionRefsR (RUnderApp _ n _ args) = (n, 0) :: concatMap externalFunctionRefsL args
externalFunctionRefsR (RApp _ _ c a) = externalFunctionRefsL c ++ externalFunctionRefsL a
externalFunctionRefsR (RLet _ _ _ value body) = externalFunctionRefsR value ++ externalFunctionRefsR body
externalFunctionRefsR (RCon _ _ _ _ args reuseFrom) =
    concatMap externalFunctionRefsL args ++ maybe [] externalFunctionRefsL reuseFrom
externalFunctionRefsR (ROp _ _ _ args postDrop) =
    concatMap externalFunctionRefsL (toList args) ++ concatMap externalFunctionRefsL postDrop
externalFunctionRefsR (RExtPrim _ _ _ args postDrop) =
    concatMap externalFunctionRefsL args ++ concatMap externalFunctionRefsL postDrop
externalFunctionRefsR (RStructGet _ structVar _ _ postDrop) =
    externalFunctionRefsL structVar ++ concatMap externalFunctionRefsL postDrop
externalFunctionRefsR (RStructSet _ structVar _ _ value postDrop) =
    externalFunctionRefsL structVar ++ externalFunctionRefsL value ++ concatMap externalFunctionRefsL postDrop
externalFunctionRefsR (RCmpCase _ _ args postDrop t f) =
    concatMap externalFunctionRefsL (toList args) ++ concatMap externalFunctionRefsL postDrop
    ++ externalFunctionRefsR t ++ externalFunctionRefsR f
externalFunctionRefsR (RConCase _ sc alts mDef) =
    let altsUsed = concatMap (\(MkRConAlt _ _ _ _ body) => externalFunctionRefsR body) alts
    in externalFunctionRefsL sc ++ altsUsed ++ maybe [] externalFunctionRefsR mDef
externalFunctionRefsR (RConstCase _ sc alts mDef) =
    let altsUsed = concatMap (\(MkRConstAlt _ body) => externalFunctionRefsR body) alts
    in externalFunctionRefsL sc ++ altsUsed ++ maybe [] externalFunctionRefsR mDef
externalFunctionRefsR (RPrimVal _ _) = []
externalFunctionRefsR (RErased _) = []
externalFunctionRefsR (RCrash _ _) = []
externalFunctionRefsR (RDup _ v _ body) = externalFunctionRefsL v ++ externalFunctionRefsR body
externalFunctionRefsR (RDrop _ vars body) = concatMap externalFunctionRefsL vars ++ externalFunctionRefsR body
externalFunctionRefsR (RFree _ v body) = externalFunctionRefsL v ++ externalFunctionRefsR body
externalFunctionRefsR (RReleaseReuse _ v body) = externalFunctionRefsL v ++ externalFunctionRefsR body
externalFunctionRefsR (RLoop _ _ initial prologueDrop body) =
    concatMap externalFunctionRefsL initial ++ concatMap externalFunctionRefsL prologueDrop ++ externalFunctionRefsR body
externalFunctionRefsR (RLoopContinue _ args postDrop) =
    concatMap externalFunctionRefsL args ++ concatMap externalFunctionRefsL postDrop
externalFunctionRefsR (RReuseOffer _ sc dupOnShared dropOnUnique body) =
    externalFunctionRefsL sc ++ concatMap externalFunctionRefsL dupOnShared
    ++ concatMap externalFunctionRefsL dropOnUnique ++ externalFunctionRefsR body

||| Same idea as `externalFunctionRefsR`, lifted to a whole `RCDef`.
export
externalFunctionRefsD : RCDef -> List (Name, Nat)
externalFunctionRefsD (MkRCFun _ _ _ body) = externalFunctionRefsR body
externalFunctionRefsD (MkRCCon _ _ _) = []
externalFunctionRefsD (MkRCForeign _ _ _) = []
externalFunctionRefsD (MkRCError body) = externalFunctionRefsR body
