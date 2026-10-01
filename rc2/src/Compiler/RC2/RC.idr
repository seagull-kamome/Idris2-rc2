module Compiler.RC2.RC

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Transforms upstream's named case trees to `RCExp` in two phases:
-- 1. `normalize`: lambda lifting and ANF-style conversion, with native type inference.
-- 2. `annotate`: Injects reference-counting primitives based on ownership.

import Compiler.RC2.DualABI
import Compiler.RC2.RCExp
import Compiler.RC2.Types
import Compiler.RC2.Util
import Core.CompileExpr
import Core.Context
import Core.Core
import Core.FC
import Core.TT

import Data.DPair
import Data.List
import Data.String
import Data.List.Quantifiers
import Data.List1
import Data.SortedMap
import Data.SortedSet
import Data.Vect

%default covering

||| Exact, greppable prefix `normalize`'s own `prim__getField`/
||| `prim__setField` cases (below) tag their `InternalError` with when
||| the struct/field name isn't a literal -- i.e. a definition (like
||| `System.FFI.getField` itself) that only works once its own caller
||| inlines it down to a literal, never as a standalone compiled
||| function. Whole-program compilation never actually throws this in
||| practice (such a definition's own un-inlined form isn't reachable
||| from `main` to begin with -- upstream's own reachable-set fetch
||| already excludes it). Incremental compilation's own `toIR`-scoped
||| `defs` has no such luxury -- every definition a module makes is
||| compiled for real regardless of whether anything in the *whole*
||| program still calls it un-inlined -- so `Compiler.RC2.RC2.toRCDefs`
||| (its own `incremental = True` case only) catches exactly this
||| marker and drops the offending definition instead of aborting the
||| whole module's compile, the same "unimplementable, fails at link
||| time instead" treatment `Emit.idr`'s own `hasUsableForeignImpl`
||| gives a `%foreign` declaration with no usable convention -- see
||| rc2/doc/incremental-compile.md's "no C struct support under
||| --inc rc2". A plain prefix match (not free-text `InternalError`
||| sniffing) so the catch site can't accidentally trap some unrelated
||| internal error.
export
notInlinedStructFieldMarker : String
notInlinedStructFieldMarker = "[rc2:not-inlined-struct-field]"

||| Every C struct declared by a `%foreign` signature in the program,
||| with its field list (`Compiler.RC2.Emit.Util.collectStructDefs`), for
||| `normalize` to resolve a `getField`/`setField` against.
export
data StructTable : Type where

------------------------------------------------------------------------
-- Phase 1: the named case trees -> RCExp, lambda lifting and ANF
-- normalisation in one walk (doc/lambda-lifting.md)

||| Where a lifted definition came from: the top-level definition it was
||| lifted out of, a lambda or a `Delay` (with its `LazyReason`), and how
||| many parameters of its own it takes after the captured ones (none
||| for a `Delay`'s thunk; doc/lazy-memoization.md).
public export
data LiftOrigin = FromLambda | FromDelay LazyReason

public export
record LiftInfo where
  constructor MkLiftInfo
  parent : Name
  origin : LiftOrigin
  params : Nat

data Lifts : Type where
data Captures : Type where

record LiftState where
  constructor MkLiftState
  basename : Name
  nextName : Int
  lifted : List (Name, RCDef)
  infos : List (Name, LiftInfo)

||| One function body being normalized: the id of every name bound in it,
||| its scope innermost first (the order a lifted lambda takes its
||| captures in), and, in a lambda, the outer names it captures, each
||| numbered where it is first read.
record Frame where
  constructor MkFrame
  env : SortedMap Name Int
  scope : List Name
  captures : Maybe (Ref Captures (SortedMap Name Int))

bindName : Name -> Int -> Frame -> Frame
bindName x i fr = { env $= insert x i, scope $= (x ::) } fr

lookupVar : {auto v : Ref VarId Int} -> Frame -> Name -> Core Int
lookupVar fr x = case lookup x (env fr) of
    Just i => pure i
    Nothing => case captures fr of
        Nothing => throw $ InternalError "[rc2] normalize: \{show x} is not in scope"
        Just ref => do
            caps <- get Captures {ref}
            case lookup x caps of
                 Just i => pure i
                 Nothing => do
                     i <- freshVarId
                     put Captures {ref} (insert x i caps)
                     pure i

genName : {auto l : Ref Lifts LiftState} -> Core Name
genName = do
    st <- get Lifts
    put Lifts ({ nextName := nextName st + 1 } st)
    pure $ mkName (basename st) (nextName st)
  where
    mkName : Name -> Int -> Name
    mkName (NS ns b) i = NS ns (mkName b i)
    mkName (UN n) i = MN (displayUserName n) i
    mkName (DN _ n) i = mkName n i
    mkName (CaseBlock outer inner) i = MN ("case block in " ++ outer ++ " (" ++ show inner ++ ")") i
    mkName (WithBlock outer inner) i = MN ("with block in " ++ outer ++ " (" ++ show inner ++ ")") i
    mkName n i = MN (show n) i

||| Check if Constant is a two-way Bool (0 or 1).
constantBoolValue : Constant -> Maybe Bool
constantBoolValue (I 0) = Just False
constantBoolValue (I 1) = Just True
constantBoolValue (I8 0) = Just False
constantBoolValue (I8 1) = Just True
constantBoolValue (I16 0) = Just False
constantBoolValue (I16 1) = Just True
constantBoolValue (I32 0) = Just False
constantBoolValue (I32 1) = Just True
constantBoolValue (I64 0) = Just False
constantBoolValue (I64 1) = Just True
constantBoolValue (B8 0) = Just False
constantBoolValue (B8 1) = Just True
constantBoolValue (B16 0) = Just False
constantBoolValue (B16 1) = Just True
constantBoolValue (B32 0) = Just False
constantBoolValue (B32 1) = Just True
constantBoolValue (B64 0) = Just False
constantBoolValue (B64 1) = Just True
constantBoolValue (BI 0) = Just False
constantBoolValue (BI 1) = Just True
constantBoolValue _ = Nothing

||| If `alts` and `mDef` form an exhaustive two-way Bool match,
||| return the (True, False) branch pair; otherwise Nothing.
boolBranches : List NamedConstAlt -> Maybe NamedCExp -> Maybe (NamedCExp, NamedCExp)
boolBranches [MkNConstAlt c body] (Just other) =
    case constantBoolValue c of
         Just True  => Just (body, other)
         Just False => Just (other, body)
         Nothing    => Nothing
boolBranches [MkNConstAlt c1 b1, MkNConstAlt c2 b2] Nothing =
    case (constantBoolValue c1, constantBoolValue c2) of
         (Just True, Just False) => Just (b1, b2)
         (Just False, Just True) => Just (b2, b1)
         _ => Nothing
boolBranches _ _ = Nothing

||| A closure application's head and all its arguments: nested
||| applications of something other than a name are one application
||| (`doc/rapp-nary-closure-apply.md`). A `Force` is not an application
||| (`RForce`, `doc/lazy-memoization.md`).
appChain : NamedCExp -> List NamedCExp -> (NamedCExp, List NamedCExp)
appChain e@(NmApp _ (NmRef _ _) _) acc = (e, acc)
appChain (NmApp _ g as) acc = appChain g (as ++ acc)
appChain g acc = (g, acc)

nmFC : NamedCExp -> FC
nmFC (NmLocal fc _) = fc
nmFC (NmRef fc _) = fc
nmFC (NmLam fc _ _) = fc
nmFC (NmLet fc _ _ _) = fc
nmFC (NmApp fc _ _) = fc
nmFC (NmCon fc _ _ _ _) = fc
nmFC (NmOp fc _ _) = fc
nmFC (NmExtPrim fc _ _) = fc
nmFC (NmForce fc _ _) = fc
nmFC (NmDelay fc _ _) = fc
nmFC (NmConCase fc _ _ _) = fc
nmFC (NmConstCase fc _ _ _) = fc
nmFC (NmPrimVal fc _) = fc
nmFC (NmErased fc) = fc
nmFC (NmCrash fc _) = fc

||| `fieldName` of the C struct `structName`, resolved against the program's
||| `%foreign` signatures (`StructTable`).
structField : {auto st : Ref StructTable (SortedMap String (List (String, CFType)))} ->
              FC -> (structName : String) -> (fieldName : String) -> Core StructField
structField fc structName fieldName = do
    tbl <- get StructTable
    let Just fs = lookup structName tbl
        | Nothing => throw $ GenericMsg fc "[rc2] struct \{structName} is used by getField/setField but appears in no %foreign signature"
    let Just (Element ty isField) = lookupField fieldName fs
        | Nothing => throw $ GenericMsg fc "[rc2] struct \{structName} has no field \{fieldName} in its %foreign declaration"
    pure (MkStructField structName fs fieldName ty isField)

0 Norm : Type -> Type
Norm a = {auto v : Ref VarId Int} -> {auto st : Ref StructTable (SortedMap String (List (String, CFType)))} ->
         {auto l : Ref Lifts LiftState} -> a

mutual
    ||| Let-bind compound expressions to fresh locals to ensure ANF normal form.
    bindOne : Norm (Frame -> NamedCExp -> (RCLocal -> Core RCExp) -> Core RCExp)
    bindOne fr (NmLocal fc x) k = k (RCLoc !(lookupVar fr x))
    bindOne fr (NmErased fc) k = k RCNull
    bindOne fr e@(NmPrimVal fc c) k =
        case litRep c of
             Just _  => k (RCConst c)
             Nothing => case c of
                  Str _ => k (RCConst c)
                  BI x  => if immInt64 x
                              then k (RCConst c)
                              else bindCompound fr e k
                  _     => bindCompound fr e k
    bindOne fr e@(NmCon fc n ci tag []) k =
        if ci == NIL || ci == NOTHING || ci == ZERO || ci == UNIT
           then k RCNull
           else case tag of
                     Just t  => k (RCEmptyCon n ci t)
                     Nothing => bindCompound fr e k
    bindOne fr e k = bindCompound fr e k

    bindCompound : Norm (Frame -> NamedCExp -> (RCLocal -> Core RCExp) -> Core RCExp)
    bindCompound fr e k
        = do i <- freshVarId
             eRC <- normalize fr e
             let rep = maybe RBoxed RNative (repOf eRC)
             rest <- k (RCLoc i)
             pure $ RLet (nmFC e) i rep eRC rest

    bindMany : Norm (Frame -> List NamedCExp -> (List RCLocal -> Core RCExp) -> Core RCExp)
    bindMany fr [] k = k []
    bindMany fr (x :: xs) k =
        bindOne fr x (\rx => bindMany fr xs (\rxs => k (rx :: rxs)))

    bindManyV : Norm (Frame -> Vect n NamedCExp -> (Vect n RCLocal -> Core RCExp) -> Core RCExp)
    bindManyV fr [] k = k []
    bindManyV fr (x :: xs) k =
        bindOne fr x (\rx => bindManyV fr xs (\rxs => k (rx :: rxs)))

    normalize : Norm (Frame -> NamedCExp -> Core RCExp)
    normalize fr (NmLocal fc x) = pure $ RV fc (RCLoc !(lookupVar fr x))
    normalize fr (NmRef fc n) = pure $ RAppName fc Nothing n []
    normalize fr (NmLam fc x b) = lambda fr fc FromLambda [x] b
    -- A body that is already a value computes nothing when forced, so it
    -- is that value, with no cell; `RForce` returns a non-cell as is
    -- (doc/lazy-memoization.md, "`Delay`").
    normalize fr (NmDelay fc lr b) =
        if isValue b
           then normalize fr b
           else do
               (n, locs) <- lift fr fc (FromDelay lr) [] b
               pure $ RDelay fc lr n locs
      where
        atom : NamedCExp -> Bool
        atom (NmLocal _ _) = True
        atom (NmPrimVal _ _) = True
        atom (NmErased _) = True
        atom _ = False

        -- Not a bare variable: it may itself be a lazy value, which
        -- `Force` must return rather than force.
        isValue : NamedCExp -> Bool
        isValue (NmPrimVal _ _) = True
        isValue (NmErased _) = True
        isValue (NmLam _ _ _) = True
        isValue (NmCon _ _ _ _ args) = all atom args
        isValue _ = False
    normalize fr (NmApp fc (NmRef _ n) args) =
        bindMany fr args (\locs => pure $ RAppName fc Nothing n locs)
    normalize fr e@(NmApp fc _ _) = applyChain fr fc e
    normalize fr (NmForce fc lr t) = bindOne fr t (\tl => pure $ RForce fc lr tl [])
    normalize fr (NmLet fc x val body) = do
        i <- freshVarId
        valRC <- normalize fr val
        let rep = maybe RBoxed RNative (repOf valRC)
        bodyRC <- normalize (bindName x i fr) body
        pure $ RLet fc i rep valRC bodyRC
    normalize fr (NmCon fc n ci tag args) =
        -- reuseFrom is always Nothing here -- Compiler.RC2.Reuse fills
        -- it in as its own dedicated pass, after Phase 1 and 2 are both
        -- done (see RCExp.idr's own doc comment on RCon).
        bindMany fr args (\locs => pure $ RCon fc n ci tag locs Nothing)
    normalize fr (NmOp fc op args) =
        -- postDrop is always [] here -- Phase 2 (`annotate`) fills it in
        -- once ownership is known (see RCExp.idr's ROp doc comment).
        bindManyV fr args (\locs => pure $ ROp fc Nothing op locs [])
    -- `getField`/`setField` become dedicated RStructGet/RStructSet
    -- nodes (doc/c-struct-support.md, "Design"); the argument shapes
    -- are that document's "A concrete example".
    normalize fr (NmExtPrim fc (NS _ (UN (Basic "prim__getField"))) [sn, _, _, sv, fn, _]) =
        bindOne fr sn (\snl => bindOne fr sv (\svl => bindOne fr fn (\fnl =>
            case (snl, fnl) of
                 (RCConst (Str structName), RCConst (Str fieldName)) =>
                     (\sf => RStructGet fc svl sf []) <$> structField fc structName fieldName
                 _ => throw $ InternalError
                        (notInlinedStructFieldMarker ++ " prim__getField: struct/field name must be string literals"))))
    normalize fr (NmExtPrim fc (NS _ (UN (Basic "prim__setField"))) [sn, _, _, sv, fn, _, vl, _]) =
        bindOne fr sn (\snl => bindOne fr sv (\svl => bindOne fr fn (\fnl => bindOne fr vl (\vll =>
            case (snl, fnl) of
                 (RCConst (Str structName), RCConst (Str fieldName)) =>
                     (\sf => RStructSet fc svl sf vll []) <$> structField fc structName fieldName
                 _ => throw $ InternalError
                        (notInlinedStructFieldMarker ++ " prim__setField: struct/field name must be string literals")))))
    normalize fr (NmExtPrim fc p args) =
        bindMany fr args (\locs => pure $ RExtPrim fc Nothing p locs [])
    normalize fr (NmConCase fc sc alts mDef) =
        bindOne fr sc (\scl => do
            alts' <- traverse (normalizeConAlt fr) alts
            mDef' <- traverseOpt (normalize fr) mDef
            pure $ RConCase fc scl alts' mDef')
    normalize fr (NmConstCase fc sc alts mDef) = do
        fused <- tryFuseCompare fr sc alts mDef
        case fused of
             Just e => pure e
             Nothing =>
                 bindOne fr sc (\scl => do
                     alts' <- traverse (\(MkNConstAlt c b) => MkRConstAlt c <$> normalize fr b) alts
                     mDef' <- traverseOpt (normalize fr) mDef
                     pure $ RConstCase fc scl alts' mDef')
    normalize fr (NmPrimVal fc c) = pure $ RPrimVal fc c
    normalize fr (NmErased fc) = pure $ RErased fc
    normalize fr (NmCrash fc msg) = pure $ RCrash fc msg

    applyChain : Norm (Frame -> FC -> NamedCExp -> Core RCExp)
    applyChain fr fc e = case appChain e [] of
        (base, []) => normalize fr base
        (base, x :: xs) =>
            bindOne fr base (\basel => bindOne fr x (\xl => bindMany fr xs (\xsl => pure $ RApp fc Nothing basel (xl ::: xsl))))

    normalizeConAlt : Norm (Frame -> NamedConAlt -> Core RConAlt)
    normalizeConAlt fr (MkNConAlt n ci tag args body) = do
        argIds <- traverse (const freshVarId) args
        let fr' = foldr (\(x, i), f => bindName x i f) fr (zip args argIds)
        MkRConAlt n ci tag argIds <$> normalize fr' body

    ||| A lambda (nested ones merged) becomes a definition of its own,
    ||| taking the names it captures, in scope order, then its own
    ||| parameters; here it is a partial application of that definition.
    lambda : Norm (Frame -> FC -> LiftOrigin -> List Name -> NamedCExp -> Core RCExp)
    lambda fr fc origin bound (NmLam _ x b) = lambda fr fc origin (x :: bound) b
    lambda fr fc origin bound body = do
        (n, locs) <- lift fr fc origin bound body
        pure $ RUnderApp fc n (length bound) locs

    ||| The definition `lambda` builds, and the captures to pass it. A
    ||| `Delay` uses it directly with no parameters of its own (its body
    ||| is never merged with a lambda inside it): the thunk.
    lift : Norm (Frame -> FC -> LiftOrigin -> List Name -> NamedCExp -> Core (Name, List RCLocal))
    lift fr fc origin bound body = do
        ref <- newRef Captures (the (SortedMap Name Int) empty)
        boundIds <- traverse (const freshVarId) bound
        let inner = MkFrame (fromList (zip bound boundIds)) (bound ++ scope fr) (Just ref)
        bodyRC <- normalize inner body
        caps <- get Captures {ref}
        let ordered = sortBy (\(a, _), (b, _) => compare (position a) (position b)) (SortedMap.toList caps)
        locs <- traverse (\(x, _) => RCLoc <$> lookupVar fr x) ordered
        n <- genName
        st <- get Lifts
        put Lifts ({ lifted $= ((n, MkRCFun (map (\(_, i) => (i, RBoxed)) ordered ++ map (\i => (i, RBoxed)) (reverse boundIds)) RBoxed False bodyRC) ::)
                   , infos $= ((n, MkLiftInfo (basename st) origin (length bound)) ::) } st)
        pure (n, locs)
      where
        position : Name -> Nat
        position x = maybe (length (scope fr)) finToNat (findIndex (== x) (scope fr))

    ||| Shared body for each `tryFuseCompare` clause below, each of which
    ||| matches one comparison constructor directly so that `args` is a
    ||| `Vect 2` and the `IsCmp` proof is at hand.
    tryFuseCompareOp : Norm (Frame -> FC -> CmpOp -> Vect 2 NamedCExp ->
                             List NamedConstAlt -> Maybe NamedCExp -> Core (Maybe RCExp))
    tryFuseCompareOp fr fc op args alts mDef =
        if not (nativeEligible (cmpOpTy op))
           then pure Nothing
           else case boolBranches alts mDef of
                     Nothing => pure Nothing
                     Just (trueL, falseL) => do
                         trueRC <- normalize fr trueL
                         falseRC <- normalize fr falseL
                         Just <$> bindManyV fr args (\locs => pure $ RCmpCase fc op locs [] trueRC falseRC)

    ||| If `sc` is a native-eligible boolean comparison and `alts`/`mDef`
    ||| form a two-way match on Idris2's own Bool encoding, fuse the whole
    ||| thing into an `RCmpCase`: the comparison's Boxed Bool is never
    ||| materialised. `Nothing` leaves `normalize` to its ordinary case.
    tryFuseCompare : Norm (Frame -> NamedCExp -> List NamedConstAlt -> Maybe NamedCExp -> Core (Maybe RCExp))
    tryFuseCompare fr (NmOp fc (LT ty) args) alts mDef = tryFuseCompareOp fr fc (Element (LT ty) IsLT) args alts mDef
    tryFuseCompare fr (NmOp fc (GT ty) args) alts mDef = tryFuseCompareOp fr fc (Element (GT ty) IsGT) args alts mDef
    tryFuseCompare fr (NmOp fc (EQ ty) args) alts mDef = tryFuseCompareOp fr fc (Element (EQ ty) IsEQ) args alts mDef
    tryFuseCompare fr (NmOp fc (LTE ty) args) alts mDef = tryFuseCompareOp fr fc (Element (LTE ty) IsLTE) args alts mDef
    tryFuseCompare fr (NmOp fc (GTE ty) args) alts mDef = tryFuseCompareOp fr fc (Element (GTE ty) IsGTE) args alts mDef
    tryFuseCompare _ _ _ _ = pure Nothing

------------------------------------------------------------------------
-- Phase 2: reference-counting annotation (RCExp -> RCExp)
--
-- Ownership bookkeeping (what's "owned" vs. still needed later, so must be
-- borrowed) is unchanged from the original design; the only difference is
-- that a borrow now materialises as an explicit `RDup` node wrapping the
-- consuming expression, instead of a flag on the occurrence.

Owned : Type
Owned = SortedSet RCLocal

||| Wrap `e` in an RDup for each variable in `needed` (order doesn't
||| matter between independent increments).
wrapDups : FC -> List RCLocal -> RCExp -> RCExp
wrapDups fc needed e = foldr (\v, acc => RDup fc v 0 acc) e needed

||| Fold `f` over every RConAlt's own body and (if present) the default,
||| unioning the `SortedSet RCLocal` results -- the shared shape behind
||| both `nativeLocalsR`'s and `alwaysUnboxedBoxedLocalsR`'s own RConCase
||| cases (they only differ in which function they recurse with).
foldConAltsR : (RCExp -> SortedSet RCLocal) -> List RConAlt -> Maybe RCExp -> SortedSet RCLocal
foldConAltsR f alts mDef =
    let altsNs = map (\(MkRConAlt _ _ _ _ body) => f body) alts in
    concat $ maybe altsNs (\d => f d :: altsNs) mDef

||| As `foldConAltsR`, for `RConstAlt`.
foldConstAltsR : (RCExp -> SortedSet RCLocal) -> List RConstAlt -> Maybe RCExp -> SortedSet RCLocal
foldConstAltsR f alts mDef =
    let altsNs = map (\(MkRConstAlt _ body) => f body) alts in
    concat $ maybe altsNs (\d => f d :: altsNs) mDef

||| Every RLet-bound local Phase 1 decided is Native, collected once per
||| top-level definition so Phase 2 can consult it directly. A native
||| local's *use* carries no Rep information of its own (only the RLet
||| node that bound it does), and it never participates in reference
||| counting at all -- no refcount, so it must never be dup'd, dropped, or
||| freed, regardless of how many times or where it's read. Operates on
||| Phase 1's output, before `annotate` has inserted any RDup/RDrop/RFree,
||| so no case for those is needed here.
nativeLocalsR : RCExp -> SortedSet RCLocal
nativeLocalsR (RLet _ var rep value body) =
    let vs = union (nativeLocalsR value) (nativeLocalsR body) in
    case rep of
         RBoxed => vs
         -- RInlineNative never actually produced until `annotate` (Phase 2)
         -- runs, which is strictly after this (Phase-1-output-consuming)
         -- function -- same native-ness as RNative regardless, kept total
         -- rather than assumed unreachable.
         _ => insert (RCLoc var) vs
nativeLocalsR (RConCase _ _ alts mDef) = foldConAltsR nativeLocalsR alts mDef
nativeLocalsR (RConstCase _ _ alts mDef) = foldConstAltsR nativeLocalsR alts mDef
nativeLocalsR (RCmpCase _ _ _ _ t f) = union (nativeLocalsR t) (nativeLocalsR f)
nativeLocalsR (RMemoize _ _ _ body) = nativeLocalsR body
nativeLocalsR _ = empty

||| Every genuine RCLoc used as an operand of a native op at a position
||| whose PrimType is `Types.alwaysUnboxed` (Int8/16/32, Bits8/16/32,
||| Char): such an operand is *always* a tagged pointer at runtime, by
||| Idris2's own type discipline (a single local can't have two
||| different types), regardless of how else it's declared (typically a
||| Boxed function argument -- the calling convention itself is
||| unchanged) or used elsewhere. A single qualifying use site is
||| therefore sufficient evidence for the *whole* variable. Folded into
||| `natives` in annotateDef alongside nativeLocalsR's genuinely-native
||| locals -- both end up meaning the same thing to every consumer of
||| `natives` (`splitBorrows`, `boxedOperands`, `RV`, RLet's owned'/
||| dropDeadLet): no dup/drop/free, ever, for this local. The difference
||| is *why*: nativeLocalsR's locals have no refcount because they're
||| not even boxed; this function's locals are boxed and do have one,
||| it's just that idris2rc2_dup/drop/free on them were always going to
||| be unconditional no-ops (support/rc2/idris2rc2_datatypes.h), so generating the
||| calls at all is pure waste. Operates on Phase 1's output, same as
||| nativeLocalsR and for the same reason.
||| `args`, filtered down to the genuine `RCLoc`s among them, if `mty`
||| says they're at an always-unboxed operand position -- the shared
||| core of `alwaysUnboxedBoxedLocalsR`'s ROp and RCmpCase cases, which
||| only differ in *how* they derive `mty`: an `ROp`'s own operand type
||| needs `opArgTyFor`'s Cast-source refinement (its operand type can
||| differ from its result type); a comparison's is already exactly its
||| shared operand type (`cmpOpTy`), no refinement needed.
alwaysUnboxedArgs : Maybe PrimType -> Vect n RCLocal -> SortedSet RCLocal
alwaysUnboxedArgs Nothing _ = empty
alwaysUnboxedArgs (Just ty) args =
    if alwaysUnboxed ty then fromList (filter isRealLoc (toList args)) else empty
  where
    isRealLoc : RCLocal -> Bool
    isRealLoc (RCLoc _) = True
    isRealLoc _ = False

alwaysUnboxedBoxedLocalsR : RCExp -> SortedSet RCLocal
alwaysUnboxedBoxedLocalsR (RLet _ _ _ value body) =
    union (alwaysUnboxedBoxedLocalsR value) (alwaysUnboxedBoxedLocalsR body)
alwaysUnboxedBoxedLocalsR (ROp _ _ op args _) =
    alwaysUnboxedArgs (map (\ty => opArgTyFor ty op) (opResultRep op)) args
alwaysUnboxedBoxedLocalsR (RConCase _ _ alts mDef) = foldConAltsR alwaysUnboxedBoxedLocalsR alts mDef
alwaysUnboxedBoxedLocalsR (RConstCase _ _ alts mDef) = foldConstAltsR alwaysUnboxedBoxedLocalsR alts mDef
alwaysUnboxedBoxedLocalsR (RCmpCase _ op args _ t f) =
    union (alwaysUnboxedArgs (Just (cmpOpTy op)) args)
          (union (alwaysUnboxedBoxedLocalsR t) (alwaysUnboxedBoxedLocalsR f))
alwaysUnboxedBoxedLocalsR (RMemoize _ _ _ body) = alwaysUnboxedBoxedLocalsR body
alwaysUnboxedBoxedLocalsR _ = empty

||| Which of `vars` need a dup: thread (and shrink) `owned` exactly as
||| before -- the *first* occurrence of an owned variable moves it (no dup
||| needed), any later occurrence (or one that was never owned to begin
||| with) needs a dup -- except a `natives`-listed local, which never needs
||| a dup (or any refcount op at all) no matter how it's used. An
||| `RCConst`/`RCEmptyCon` are skipped the same way as a native -- neither
||| was ever a real heap value to begin with (see RCExp.idr's module note
||| on RCLocal); `RCNull` is skipped for the same reason (it's always
||| either an erased value or one of the four NULL-mapped nullary
||| constructors, see `bindOne` -- never a real refcounted heap value).
splitBorrows : (natives : SortedSet RCLocal) -> Owned -> List RCLocal -> List RCLocal
splitBorrows _ _ [] = []
splitBorrows natives owned (RCNull :: vars) = splitBorrows natives owned vars
splitBorrows natives owned (RCConst _ :: vars) = splitBorrows natives owned vars
splitBorrows natives owned (RCEmptyCon {} :: vars) = splitBorrows natives owned vars
splitBorrows natives owned (RCConstCon {} :: vars) = splitBorrows natives owned vars
splitBorrows natives owned (RCConstClosure {} :: vars) = splitBorrows natives owned vars
splitBorrows natives owned (v :: vars) =
    if contains v natives
        then splitBorrows natives owned vars
        else if contains v owned
                then splitBorrows natives (delete v owned) vars
                else v :: splitBorrows natives owned vars

splitBorrowsV : (natives : SortedSet RCLocal) -> Owned -> Vect n RCLocal -> List RCLocal
splitBorrowsV natives owned = splitBorrows natives owned . toList

||| Which of `vars` are their own last use here (still in `owned`, not
||| `natives`) -- for `RStructGet`/`RStructSet` (see doc/c-struct-support.md's
||| "Design" section): a plain C pointer dereference/field read never
||| needs a `dup` the way an `ROp` operand can (there's no C-level
||| reason to copy a pointer, or reread an already-Boxed operand's own
||| field, just to use it), but an operand still needs dropping once
||| read if this is genuinely its last use, or it leaks. Unlike
||| `splitBorrows`, never inserts a `dup` for a still-alive operand --
||| there's nothing to do here for one. Processed left-to-right,
||| consuming `owned` as it goes (mirroring `splitBorrows`'s own
||| occurrence-order handling), so the same local occurring twice (a
||| degenerate case -- e.g. `RStructSet`'s `structVar`/`value` happening
||| to be the same local) is only marked drop-worthy on its first
||| occurrence, not both.
dropIfLastUse : (natives : SortedSet RCLocal) -> Owned -> List RCLocal -> List RCLocal
dropIfLastUse _ _ [] = []
dropIfLastUse natives owned (RCNull :: vars) = dropIfLastUse natives owned vars
dropIfLastUse natives owned (RCConst _ :: vars) = dropIfLastUse natives owned vars
dropIfLastUse natives owned (RCEmptyCon {} :: vars) = dropIfLastUse natives owned vars
dropIfLastUse natives owned (RCConstCon {} :: vars) = dropIfLastUse natives owned vars
dropIfLastUse natives owned (RCConstClosure {} :: vars) = dropIfLastUse natives owned vars
dropIfLastUse natives owned (v :: vars) =
    if contains v natives
        then dropIfLastUse natives owned vars
        else if contains v owned
                then v :: dropIfLastUse natives (delete v owned) vars
                else dropIfLastUse natives owned vars

||| Which of an `ROp`'s operands need dropping once it's done reading
||| them -- i.e. every genuinely Boxed one (native locals and RCConst
||| never had a refcount to drop; see RCExp.idr's module notes on both),
||| with one entry per *occurrence* so a repeated operand (`x + x`) gets
||| dropped once per read. Unlike `splitBorrows`, this doesn't consult
||| `owned` at all: an op's read always needs exactly one drop per Boxed
||| occurrence regardless of whether that occurrence was moved-in
||| (owned) or dup'd-for-borrow -- the dup (if any) exists precisely to
||| give this read its own reference to consume. Becomes `ROp`'s
||| `postDrop` field (see its doc comment) -- this is the one place
||| Compiler.RC2.Emit used to independently re-derive an ownership
||| decision instead of just lowering one; now it doesn't have to.
boxedOperands : (natives : SortedSet RCLocal) -> List RCLocal -> List RCLocal
boxedOperands natives = filter isBoxedOperand
  where
    isBoxedOperand : RCLocal -> Bool
    isBoxedOperand RCNull = False
    isBoxedOperand (RCConst _) = False
    isBoxedOperand (RCEmptyCon {}) = False
    isBoxedOperand (RCConstCon {}) = False
    isBoxedOperand (RCConstClosure {}) = False
    isBoxedOperand v = not (contains v natives)

mutual
    branchBody : SortedSet RCLocal -> SortedSet RCLocal -> RCExp -> Core RCExp
    branchBody natives ownedWithArgs body = do
        -- `ownedUsedIn` rather than `intersection ... (freeLocalsR body)`:
        -- the same answer, without building a set of every local below
        -- this arm just to keep the handful this scope owns. See its own
        -- doc comment for the measurement that motivated it.
        let actualOwned = ownedUsedIn ownedWithArgs body
        let shouldDrop = Prelude.toList (difference ownedWithArgs actualOwned)
        rest <- annotate natives actualOwned body
        pure $ case shouldDrop of
                    [] => rest
                    _  => RDrop emptyFC shouldDrop rest

    annotate : SortedSet RCLocal -> Owned -> RCExp -> Core RCExp
    -- Immortal, same reasoning as splitBorrows/dropIfLastUse/
    -- boxedOperands above -- never needs a dup, `owned`/`natives`
    -- (variable sets) never contain it anyway.
    annotate natives owned e@(RV _ (RCConstCon {})) = pure e
    -- Same reasoning as the RCConstCon intercept just above -- an
    -- immortal folded closure is never tracked in natives/owned either,
    -- and would otherwise get a wasted (though harmless) RDup here.
    annotate natives owned e@(RV _ (RCConstClosure {})) = pure e
    -- `RCConst`/`RCEmptyCon`/`RCNull` need the exact same three
    -- intercepts, for the exact same reason -- `Compiler.RC2.ConstFold`
    -- gained the ability to fold a whole `RConCase` (a destructured
    -- field bound via `insertConArgs`, or a whole-program CAF's own
    -- value via `RAppName`'s own fold arm) straight down to a BARE `RV`
    -- of one of these forms, with no enclosing `RLet` left for `annotate`
    -- to have already special-cased -- previously only `RCConstCon`/
    -- `RCConstClosure` could ever reach this point unaccompanied
    -- (`splitBorrows`/`dropIfLastUse` above already exclude all five
    -- forms uniformly; this fallthrough hadn't needed to, before that
    -- fold existed). Without this, the generic `RV fc v` case below
    -- wraps it in a real `RDup` (since neither set ever tracks a
    -- constant-form value), and `Compiler.RC2.Emit.Util`'s own `varName`
    -- has no real rendering for any of the five reaching it that way
    -- (all five say so in their own doc comments) -- not just wasted, a
    -- genuine C compile error.
    annotate natives owned e@(RV _ (RCConst _)) = pure e
    annotate natives owned e@(RV _ (RCEmptyCon {})) = pure e
    annotate natives owned e@(RV _ RCNull) = pure e
    annotate natives owned (RV fc v) =
        pure $ if contains v natives || contains v owned then RV fc v else RDup fc v 0 (RV fc v)
    annotate natives owned (RAppName fc lazy n args) =
        pure $ wrapDups fc (splitBorrows natives owned args) (RAppName fc lazy n args)
    annotate natives owned (RUnderApp fc n missing args) =
        pure $ wrapDups fc (splitBorrows natives owned args) (RUnderApp fc n missing args)
    annotate natives owned (RDelay fc lr n caps) =
        pure $ wrapDups fc (splitBorrows natives owned caps) (RDelay fc lr n caps)
    annotate natives owned (RApp fc lazy c args) =
        pure $ wrapDups fc (splitBorrows natives owned (c :: forget args)) (RApp fc lazy c args)
    annotate natives owned (RLet fc var rep value body) = do
        -- Only `var` itself and the currently-owned locals are ever
        -- asked about below, so `ownedUsedIn` answers both questions in
        -- one early-exiting walk instead of building `freeLocalsR body`
        -- -- a set of every local in the rest of the chain -- at every
        -- single `RLet`. See `ownedUsedIn`'s own doc comment.
        let usedVars = ownedUsedIn (insert (RCLoc var) owned) body
        let borrowVal = delete (RCLoc var) usedVars
        -- Never add a `natives`-listed local to `owned` -- whether it's
        -- Native (no refcount at all) or a Boxed-but-alwaysUnboxed local
        -- (has one, but dup/drop on it are unconditional no-ops anyway,
        -- see alwaysUnboxedBoxedLocalsR's comment), it has nothing for
        -- `owned` to track (see `splitBorrows`/`RV` above, which are
        -- what actually decide whether a use needs a dup; this just
        -- keeps `owned` itself limited to locals that genuinely need
        -- tracking, which `dropUnusedOwnedVars`/`branchBody` rely on).
        let owned' = if contains (RCLoc var) natives
                        then borrowVal
                        else if contains (RCLoc var) usedVars then insert (RCLoc var) borrowVal else borrowVal
        valueRC <- annotate natives (owned `difference` borrowVal) value
        bodyRC <- annotate natives owned' body
        if contains (RCLoc var) usedVars
           then pure $ RLet fc var (inlineableRep rep valueRC var bodyRC) valueRC bodyRC
           else pure $ RLet fc var rep valueRC (dropDeadLet fc natives rep (RCLoc var) valueRC bodyRC)
      where
        ||| Promote a plain `RNative ty` to `RInlineNative ty` once ownership is
        ||| fully known (called from `annotate`'s own `RLet` case, after both
        ||| `valueRC`'s `postDrop` and `bodyRC` are already computed): safe and
        ||| worthwhile exactly when `valueRC` is a bare native op and `var` is
        ||| referenced exactly once in `bodyRC` (otherwise inlining would
        ||| duplicate the op's computation). Anything else (a literal-valued
        ||| let, a multi-use one, or an already-`RBoxed` one) passes `rep`
        ||| through unchanged -- this only ever *narrows* an existing
        ||| `RNative`, never invents a new native classification `Types.repOf`
        ||| didn't already decide. Moves what used to be `Emit.idr`'s own
        ||| `tryInlineNativeOp` (a `countUsesR` tree-walk redone at *emission*
        ||| time on every RLet) into a single Phase-2 decision instead,
        ||| mirroring `ROp.postDrop` and reuse-in-place's own earlier
        ||| elevations.
        |||
        ||| `ROp`'s own non-empty `postDrop` (any Boxed operand it reads and
        ||| owes a drop -- see its own doc comment) is no obstacle here: it
        ||| just rides along on `var`'s single deferred use like the rest of
        ||| the op's own expression text. `Compiler.RC2.Emit.Util`'s InlineMap
        ||| stashes it alongside that text (`rcVarToBoxedC`/`rcVarToNativeC`'s
        ||| own doc comments), and the deferred use is exactly where it gets
        ||| discharged -- the canonical read-before-drop rule
        ||| (`Compiler.RC2.Emit`'s `emitRC` doc comment) holds regardless of
        ||| whether the op's own C statement was emitted eagerly (an ordinary
        ||| `RNative` `RLet`) or deferred to its single use (`RInlineNative`).
        inlineableRep : Rep -> RCExp -> Int -> RCExp -> Rep
        inlineableRep (RNative ty) (ROp {}) var bodyRC =
            if countUsesR (RCLoc var) bodyRC == 1 then RInlineNative ty else RNative ty
        inlineableRep rep _ _ _ = rep

        ||| Wrap `body` in the cleanup for a single dead variable: an unconditional
        ||| `RFree` if `value` (its birthplace) is a provably-unshared fresh
        ||| allocation, otherwise the ordinary checked `RDrop`. Never wraps at all
        ||| for a native (unboxed, unrefcounted) local, or for a Boxed local
        ||| that's in `natives` anyway (alwaysUnboxedBoxedLocalsR -- see its own
        ||| comment for why that's just as unconditionally a no-op).
        dropDeadLet : FC -> SortedSet RCLocal -> Rep -> RCLocal -> RCExp -> RCExp -> RCExp
        dropDeadLet fc natives RBoxed loc value body =
            if contains loc natives
               then body
               else if freeableShape value
                       then RFree fc loc body
                       else RDrop fc [loc] body
          where
            ||| Whether a just-built value (still in its pre-annotation, Phase 1
            ||| shape) is provably a brand-new, never-shared heap allocation:
            ||| constructing it always initialises refcount=1, and since we're
            ||| looking at it in exactly the position it was created, no other code
            ||| has had a chance to dup the reference yet. Safe to skip the refcount
            ||| check and free unconditionally (`RFree`) if it turns out dead.
            ||| Peels through the same synthetic-let wrapper chain `Types.repOf` does.
            freeableShape : RCExp -> Bool
            freeableShape (RLet _ _ _ _ body) = freeableShape body
            freeableShape (RCon _ _ ci _ _ _) = ci /= NIL && ci /= NOTHING && ci /= ZERO && ci /= UNIT
            freeableShape (RUnderApp _ _ _ _) = True
            freeableShape _ = False
        -- RNative/RInlineNative never need cleanup: neither is refcounted
        -- (RInlineNative never actually reaches here at all -- see
        -- `inlineableRep`'s own doc comment -- but kept total rather than
        -- assumed unreachable).
        dropDeadLet fc natives _ _ _ body = body
    annotate natives owned (RCon fc n ci tag args _) =
        -- reuseFrom stays Nothing -- Compiler.RC2.Reuse decides that in
        -- its own pass, after annotate is completely done (it needs the
        -- final RDrop lists this function produces, see its own module
        -- note).
        pure $ wrapDups fc (splitBorrows natives owned args) (RCon fc n ci tag args Nothing)
    annotate natives owned (ROp fc lazy op args _) =
        pure $ wrapDups fc (splitBorrowsV natives owned args)
                          (ROp fc lazy op args (boxedOperands natives (toList args)))
    -- Mirrors the ROp case immediately above exactly, deliberately
    -- primitive-agnostic (never inspects/branches on `p`): the
    -- compiler can't know in advance how every present-and-future
    -- ExtPrim's own C implementation handles its arguments' ownership,
    -- so `RExtPrim`'s args get the same borrow/move contract as an
    -- ordinary ROp's operands -- the callee is responsible for
    -- `idris2rc2_dup`-ing anything it wants to keep past the call (see
    -- `support/rc2/ioprims.c`), the same way any other FFI callee
    -- would. Previously a bare pass-through (`owned` never consulted
    -- at all), which leaked e.g. an IORef's own cell (`prim__newIORef`)
    -- and any argument computed fresh for the call (e.g.
    -- `modifyIORef`'s own `f val` fed into `writeIORef`) -- see
    -- doc/c-struct-support.md's own addendum for the full writeup.
    annotate natives owned (RExtPrim fc lazy p args _) =
        pure $ wrapDups fc (splitBorrows natives owned args)
                          (RExtPrim fc lazy p args (boxedOperands natives args))
    -- Never calls splitBorrows/wrapDups -- see dropIfLastUse's own doc
    -- comment and doc/c-struct-support.md's "Design" section: neither
    -- structVar nor value is ever duplicated, only dropped if this use
    -- is genuinely the last one.
    annotate natives owned (RStructGet fc structVar sf _) =
        pure $ RStructGet fc structVar sf (dropIfLastUse natives owned [structVar])
    annotate natives owned (RForce fc lr v _) =
        pure $ RForce fc lr v (dropIfLastUse natives owned [v])
    annotate natives owned (RStructSet fc structVar sf value _) =
        pure $ RStructSet fc structVar sf value (dropIfLastUse natives owned [structVar, value])
    -- `value` is consumed like an `RCon` field; `cell` is only borrowed.
    annotate natives owned (RFill fc cell k value _) =
        pure $ wrapDups fc (splitBorrows natives owned [value]) (RFill fc cell k value (dropIfLastUse natives owned [cell]))
    annotate natives owned (RCmpCase fc op args _ t f) = do
        -- Unlike ROp (always a "value" with the caller -- an enclosing
        -- RLet -- responsible for pre-shrinking `owned` before handing
        -- it over, see RLet's own borrowVal/owned' split above),
        -- RCmpCase's own two continuations (t/f) mean *this* node must
        -- do that shrinking itself: an owned arg that's never
        -- referenced again in either branch is safe to fold into the
        -- comparison's own read (a move, consumed by postDrop below,
        -- no dup) and must NOT continue into `owned` for t/f -- passing
        -- the *unrestricted* `owned` there would make each branch's own
        -- `branchBody` (which drops anything owned it doesn't use) drop
        -- the same already-consumed arg a second time. An owned arg
        -- that *does* recur in a branch is left alone (splitBorrowsV
        -- below sees it as needing a dup instead, exactly `splitBorrows`'s
        -- ordinary borrow behaviour), same as any other owned local not
        -- touched by this restriction.
        let usedLater = union (freeLocalsR t) (freeLocalsR f)
        let argsSet = fromList (toList args)
        let deadArgs = intersection argsSet (owned `difference` usedLater)
        let liveArgs = argsSet `difference` deadArgs
        let ownedForBranches = owned `difference` deadArgs
        t' <- branchBody natives ownedForBranches t
        f' <- branchBody natives ownedForBranches f
        pure $ wrapDups fc (splitBorrowsV natives (owned `difference` liveArgs) args)
                          (RCmpCase fc op args (boxedOperands natives (toList args)) t' f')
    annotate natives owned (RConCase fc sc alts mDef) = do
        alts' <- traverse (annotateConAlt natives owned sc) alts
        mDef' <- traverseOpt (branchBody natives owned) mDef
        pure $ RConCase fc sc alts' mDef'
    annotate natives owned (RConstCase fc sc alts mDef) = do
        alts' <- traverse (annotateConstAlt natives owned) alts
        mDef' <- traverseOpt (branchBody natives owned) mDef
        pure $ RConstCase fc sc alts' mDef'
    annotate natives owned e@(RPrimVal _ _) = pure e
    annotate natives owned e@(RErased _) = pure e
    annotate natives owned e@(RCrash _ _) = pure e
    annotate natives owned (RDup fc v extra body) = RDup fc v extra <$> annotate natives owned body
    annotate natives owned (RDrop fc vars body) = RDrop fc vars <$> annotate natives owned body
    annotate natives owned (RFree fc v body) = RFree fc v <$> annotate natives owned body
    -- Never actually produced until Compiler.RC2.Reuse runs, which is
    -- strictly after annotate is done with the whole definition -- kept
    -- total (as a plain pass-through) rather than assuming that can
    -- never change.
    annotate natives owned (RReleaseReuse fc v body) = RReleaseReuse fc v <$> annotate natives owned body
    -- Never actually produced until Compiler.RC2.Reuse runs, which is
    -- strictly after annotate is done with the whole definition (see
    -- RReuseOffer's own doc comment) -- kept total (as a plain
    -- pass-through), same reasoning as RReleaseReuse just above.
    annotate natives owned (RReuseOffer fc sc dupOnShared dropOnUnique body) =
        RReuseOffer fc sc dupOnShared dropOnUnique <$> annotate natives owned body
    -- Never actually produced until Compiler.RC2.Loop runs, which is
    -- strictly after annotate is done with the whole definition (it
    -- rewrites already-annotated RAppName nodes in tail position, see
    -- RLoop's own doc comment) -- kept total (as a plain pass-through),
    -- same reasoning as RReleaseReuse just above.
    annotate natives owned (RLoop fc loopParams initial prologueDrop body) =
        RLoop fc loopParams initial prologueDrop <$> annotate natives owned body
    annotate natives owned e@(RLoopContinue _ _ _) = pure e
    -- Never actually produced until Compiler.RC2.DualABI runs, which is
    -- strictly after annotate is done with the whole definition (and
    -- after Compiler.RC2.Loop too, see RAppNameRep's own doc comment)
    -- -- kept total (as a plain pass-through), same reasoning as
    -- RReleaseReuse above.
    annotate natives owned e@(RAppNameRep _ _ _ _ _ _) = pure e
    -- Never actually produced until Compiler.RC2.DualABI's own later
    -- FFI-inline pass runs (Stage 5, strictly after Stage 4's own
    -- RAppNameRep rewrite -- see RAppFFIInline's own doc comment in
    -- RCExp.idr) -- kept total (as a plain pass-through), same
    -- reasoning as RAppNameRep just above.
    annotate natives owned e@(RAppFFIInline _ _ _ _ _ _) = pure e
    -- Only produced by Compiler.RC2.DualABI (doc/struct-return.md), same
    -- reasoning as RAppNameRep above.
    annotate natives owned e@(RRetPack _ _ _ _) = pure e
    -- RMemoize only ever wraps a whole top-level 0-argument definition's
    -- entire body (Compiler.RC2.RC2's own insertMemoize, inserted right
    -- after ConstFold, strictly before this pass runs -- see
    -- doc/caf-memoization.md), so "how body's own final value should be
    -- owned" is identical to "how a plain function's own return value
    -- is owned" -- already exactly what annotateDef's own branchBody
    -- call computes for the un-wrapped case. No sink-specific ownership
    -- bookkeeping needed here: recurse with the same natives/owned
    -- context, unchanged.
    annotate natives owned (RMemoize fc n rep body) =
        RMemoize fc n rep <$> annotate natives owned body

    annotateConAlt : SortedSet RCLocal -> Owned -> RCLocal -> RConAlt -> Core RConAlt
    annotateConAlt natives owned sc (MkRConAlt name ci tag args body) = do
        -- Matching NIL/NOTHING/ZERO/UNIT consumes `sc` itself (it was only
        -- ever a NULL check, no heap object to keep owning).
        let erased = ci == NIL || ci == NOTHING || ci == ZERO || ci == UNIT
        -- `natives`-listed fields (e.g. an Int8 field extracted from a
        -- constructor and later read in an arithmetic op) don't belong
        -- in `owned` either, same reasoning as RLet's owned' above.
        let ownedWithArgs = union (fromList (RCLoc <$> args) `difference` natives)
                                   (if erased then delete sc owned else owned)
        bodyRC <- branchBody natives ownedWithArgs body
        -- No RReuseOffer here yet -- Compiler.RC2.Reuse decides that
        -- afterward, using the RDrop list this produces (see its own
        -- module note).
        pure $ MkRConAlt name ci tag args bodyRC

    annotateConstAlt : SortedSet RCLocal -> Owned -> RConstAlt -> Core RConstAlt
    annotateConstAlt natives owned (MkRConstAlt c body) = MkRConstAlt c <$> branchBody natives owned body

||| `natives` for a definition's whole body: genuinely-native RLet
||| locals (`nativeLocalsR`) plus Boxed locals provably always
||| represented as a tagged pointer (`alwaysUnboxedBoxedLocalsR`) --
||| every consumer of `natives` (`splitBorrows`, `boxedOperands`, `RV`,
||| RLet's owned'/dropDeadLet, annotateConAlt) treats both exactly the
||| same: no dup/drop/free, ever, regardless of how or how many times
||| the local is used.
definitionNatives : RCExp -> SortedSet RCLocal
definitionNatives body = union (nativeLocalsR body) (alwaysUnboxedBoxedLocalsR body)

annotateDef : RCDef -> Core RCDef
annotateDef (MkRCFun args retRep isWorker body) = do
    let natives = definitionNatives body
    -- `natives`-listed args (see definitionNatives) don't belong in
    -- `owned` either -- same reasoning as RLet's owned' above -- so
    -- they're excluded before `branchBody`'s own dropUnusedOwnedVars
    -- ever sees them, rather than relying on it to notice they're
    -- unused later (they may well be used, just never via anything
    -- owned/dup/drop cares about). The whole function body is, in every
    -- way that matters here, just a branch whose "owned with args" is
    -- its own argument list -- `branchBody` already does exactly the
    -- drop-unused-then-annotate-then-wrap sequence this needs.
    let argsVars = fromList (RCLoc <$> map fst args) `difference` natives
    MkRCFun args retRep isWorker <$> branchBody natives argsVars body
annotateDef d@(MkRCCon _ _ _) = pure d
annotateDef d@(MkRCForeign _ _ _) = pure d
annotateDef (MkRCError body) = MkRCError <$> annotate (definitionNatives body) empty body

||| A `%foreign` declaration's own return type, peeled through
||| `CFIORes` (`Compiler.RC2.DualABI.peelIORes`), must not itself be a
||| `CFFun`: there is no working C shape for a `%foreign` call to hand
||| back a closure (upstream RefC's `makeFunction(...)` names a function
||| that exists nowhere). Unchecked, it surfaces only as an undefined
||| reference at link time; here it fails with the declaration's name.
checkForeignReturn : Name -> CFType -> Core ()
checkForeignReturn n ret =
    case peelIORes ret of
         CFFun _ _ => throw $ GenericMsg EmptyFC
             "[rc2] %foreign declaration \{show n}'s own return type is a function (CFFun) -- returning a closure from a %foreign declaration isn't supported"
         _ => pure ()

||| One top-level definition, then the lambdas lifted out of it, newest
||| first, and their `LiftInfo`s.
normalizeTop : {auto v : Ref VarId Int} -> {auto st : Ref StructTable (SortedMap String (List (String, CFType)))} ->
               Name -> NamedDef -> Core (List (Name, RCDef), List (Name, LiftInfo))
normalizeTop n d = do
    l <- newRef Lifts (MkLiftState n 0 [] [])
    top <- case d of
        MkNmFun args body => do
            argIds <- traverse (const freshVarId) args
            let fr = MkFrame (fromList (zip args argIds)) args Nothing
            MkRCFun (map (\i => (i, RBoxed)) argIds) RBoxed False <$> normalize fr body
        MkNmError body => MkRCError <$> normalize (MkFrame empty [] Nothing) body
        MkNmCon tag arity nt => pure $ MkRCCon tag arity nt
        MkNmForeign ccs fargs ret => do
            checkForeignReturn n ret
            pure $ MkRCForeign ccs fargs ret
    st <- get Lifts
    pure ((n, top) :: lifted st, infos st)

||| Phase 1 over the whole program: `main` (as `__mainExpression`) and
||| its lifts first, then each definition followed by its own. In an
||| incremental compile, a definition whose `getField`/`setField` names
||| aren't literals (a constructor argument not yet inlined) is left
||| out with its lifts, to fail at link time only if it is used.
export
normalizeProgram : {auto v : Ref VarId Int} -> {auto st : Ref StructTable (SortedMap String (List (String, CFType)))} ->
                   (incremental : Bool) -> Maybe NamedCExp -> List (Name, FC, NamedDef) ->
                   Core (List (Name, RCDef), SortedMap Name LiftInfo)
normalizeProgram incremental main defs = do
    let mainDef = maybe [] (\m => [(MN "__mainExpression" 0, MkNmFun [] m)]) main
    groups <- traverse one (mainDef ++ map (\(n, _, d) => (n, d)) defs)
    pure (foldr (\(ds, _), acc => ds ++ acc) [] groups, fromList (foldr (\(_, is), acc => is ++ acc) [] groups))
  where
    one : (Name, NamedDef) -> Core (List (Name, RCDef), List (Name, LiftInfo))
    one (n, d) =
        if not incremental then normalizeTop n d
        else catch (normalizeTop n d)
                   (\err => case err of
                                 InternalError msg =>
                                     if isInfixOf notInlinedStructFieldMarker msg then pure ([], []) else throw err
                                 _ => throw err)

||| One line per lifted definition, for the `dumplifts` directive.
export
dumpLifts : SortedMap Name LiftInfo -> String
dumpLifts m = fastConcat (map line (SortedMap.toList m))
  where
    originText : LiftOrigin -> String
    originText FromLambda = "lambda"
    originText (FromDelay lr) = "delay " ++ show lr

    line : (Name, LiftInfo) -> String
    line (n, i) = show n ++ "  from " ++ show (parent i) ++ "  " ++ originText (origin i)
                  ++ "  params " ++ show (params i) ++ "\n"

||| Phase 2 (`annotateDef`) only -- run once per definition, after
||| `Compiler.RC2.RC2`'s own `ConstFold` fixpoint loop has fully
||| converged (or hit its iteration cap) on that definition's final
||| folded body.
export
toRCDefPostFold : RCDef -> Core RCDef
toRCDefPostFold = annotateDef
