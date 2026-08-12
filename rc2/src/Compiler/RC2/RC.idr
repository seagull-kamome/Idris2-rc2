module Compiler.RC2.RC

-- Lifted (Compiler.LambdaLift) -> RCExp, in two internal phases that
-- together replace what would otherwise be "convert to ANF" followed by
-- "analyse ownership over ANF": rc2 does not use Compiler.ANF at all.
--
-- Phase 1 (`normalize`) walks `Lifted` directly and produces an RCExp
-- shaped tree: every compound argument expression gets let-bound to a
-- fresh local first (the same "every argument is a variable" normal form
-- Compiler.ANF would produce), using our own independent variable-id
-- allocation (RCLocal) -- not Compiler.ANF's AVar/toANF. This is also
-- where native type inference happens: every RLet this phase builds is
-- given its final `Rep` immediately, by calling Compiler.RC2.Types.repOf
-- on the just-built value -- there is no separate Emit-time analysis, and
-- no side table; the decision is made right here, during the conversion,
-- and stored directly on the RLet node. Reference counting (RDup/RDrop/
-- RFree) is not yet inserted at this point -- Phase 1 only ever produces
-- plain variable reads (RV) with no wrapping.
--
-- Phase 2 (`annotate`) walks that shape and rebuilds it with the actual
-- reference-counting primitives inserted (see RCExp.idr's module note),
-- mirroring RC2's original borrow/ownership algorithm -- just retargeted
-- from ANF onto our own IR, and now producing explicit RDup/RDrop/RFree
-- nodes instead of a `borrowed` flag on each use. It threads each RLet's
-- `Rep` straight through unchanged (Phase 1 already decided it), and
-- additionally threads a `natives` set (every Native-rep RLet-bound local
-- in the current definition, see `nativeLocalsR`) throughout, since a
-- Native local has no refcount at all and must never be dup'd/dropped/
-- freed no matter how or how many times it's used or how the ordinary
-- Boxed owned/borrowed bookkeeping would otherwise treat it.

import Compiler.LambdaLift
import Compiler.RC2.RCExp
import Compiler.RC2.Types
import Core.CompileExpr
import Core.Context
import Core.Core
import Core.FC
import Core.Name.Scoped

import Data.SortedSet
import Data.Vect

%default covering

------------------------------------------------------------------------
-- Phase 1: Lifted -> RCExp (ANF-style normalisation, our own)

Env : Type
Env = List Int -- env !! idx = local id for de Bruijn index `idx`

lookupEnv : Nat -> Env -> Int
lookupEnv Z (x :: _) = x
lookupEnv (S k) (_ :: xs) = lookupEnv k xs
lookupEnv _ [] = assert_total $ idris_crash "INTERNAL ERROR: rc2 scope/env mismatch"

data NextVar : Type where

nextVarId : {auto v : Ref NextVar Int} -> Core Int
nextVarId = do i <- get NextVar; put NextVar (i + 1); pure i

getFC : Lifted vars -> FC
getFC (LLocal fc _) = fc
getFC (LAppName fc _ _ _) = fc
getFC (LUnderApp fc _ _ _) = fc
getFC (LApp fc _ _ _) = fc
getFC (LLet fc _ _ _) = fc
getFC (LCon fc _ _ _ _) = fc
getFC (LOp fc _ _ _) = fc
getFC (LExtPrim fc _ _ _) = fc
getFC (LConCase fc _ _ _) = fc
getFC (LConstCase fc _ _ _) = fc
getFC (LPrimVal fc _) = fc
getFC (LErased fc) = fc
getFC (LCrash fc _) = fc

||| Idris2's own encoding for a two-way Bool match at the `Constant`
||| level -- False=0/True=1, as *some* Constant kind (which one varies:
||| a bare comparison's own case tree tends to use the comparison's
||| operand-adjacent kind, an interface method wrapping it might re-tag
||| via a different one -- see RCExp.idr's own note on RCmpCase for
||| where this gets consulted). Anything else (a non-0/1 literal, or a
||| non-integer-ish Constant kind) means this isn't really matching a
||| Bool at all.
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

||| The (whenTrue, whenFalse) pair a two-way `LConstCase` decomposes
||| into, if `alts`/`mDef` really do form an exhaustive match on
||| Idris2's Bool encoding (`constantBoolValue`) -- either two explicit
||| alts (one per value, in either order) or one explicit alt plus a
||| default covering the other value. `Nothing` for anything else (a
||| non-Boolean constant switch, or a shape too irregular to trust --
||| e.g. a single alt with no default, which doesn't actually branch on
||| the comparison at all), so the caller falls back to the ordinary,
||| unfused `RConstCase` path unchanged.
boolBranches : List (LiftedConstAlt vars) -> Maybe (Lifted vars) -> Maybe (Lifted vars, Lifted vars)
boolBranches [MkLConstAlt c body] (Just other) =
    case constantBoolValue c of
         Just True  => Just (body, other)
         Just False => Just (other, body)
         Nothing    => Nothing
boolBranches [MkLConstAlt c1 b1, MkLConstAlt c2 b2] Nothing =
    case (constantBoolValue c1, constantBoolValue c2) of
         (Just True, Just False) => Just (b1, b2)
         (Just False, Just True) => Just (b2, b1)
         _ => Nothing
boolBranches _ _ = Nothing

mutual
    ||| Normalise a single (possibly compound) sub-expression: if it's
    ||| already trivial (a local/erased/native-eligible-literal), no new
    ||| binding is needed; otherwise let-bind it to a fresh local first.
    bindOne : {auto v : Ref NextVar Int} ->
              Env -> Lifted vars -> (RCLocal -> Core RCExp) -> Core RCExp
    bindOne env (LLocal {idx} fc p) k = k (RCLoc (lookupEnv idx env))
    bindOne env (LErased fc) k = k RCNull
    bindOne env e@(LPrimVal fc c) k =
        -- A native-eligible literal operand (the overwhelmingly common
        -- case -- e.g. the `2` in `d * 2`) never needs a synthetic let
        -- of its own: there's no sharing/evaluation-order reason to
        -- name a bare constant, only `bindMany`/`bindManyV`'s uniform
        -- "every argument is a variable" normal form. RCConst carries
        -- it directly (see RCExp.idr's module note) -- Emit.idr renders
        -- it as an inline literal wherever it's read, with no C
        -- declaration and no RepMap/InlineMap bookkeeping needed at
        -- all. Anything litRep doesn't cover (String, Integer, ...)
        -- falls through to the general case below unchanged -- those
        -- stay boxed regardless, and want Emit.idr's smarter
        -- constant-staging/small-int-caching machinery for `RPrimVal`,
        -- not this.
        case litRep c of
             Just _  => k (RCConst c)
             Nothing => bindCompound env e k
    bindOne env e k = bindCompound env e k

    bindCompound : {auto v : Ref NextVar Int} ->
                   Env -> Lifted vars -> (RCLocal -> Core RCExp) -> Core RCExp
    bindCompound env e k
        = do i <- nextVarId
             eRC <- normalize env e
             let rep = maybe RBoxed RNative (repOf eRC)
             rest <- k (RCLoc i)
             pure $ RLet (getFC e) i rep eRC rest

    bindMany : {auto v : Ref NextVar Int} ->
               Env -> List (Lifted vars) -> (List RCLocal -> Core RCExp) -> Core RCExp
    bindMany env [] k = k []
    bindMany env (x :: xs) k =
        bindOne env x (\rx => bindMany env xs (\rxs => k (rx :: rxs)))

    bindManyV : {auto v : Ref NextVar Int} ->
                Env -> Vect n (Lifted vars) -> (Vect n RCLocal -> Core RCExp) -> Core RCExp
    bindManyV env [] k = k []
    bindManyV env (x :: xs) k =
        bindOne env x (\rx => bindManyV env xs (\rxs => k (rx :: rxs)))

    normalize : {auto v : Ref NextVar Int} -> Env -> Lifted vars -> Core RCExp
    normalize env (LLocal {idx} fc p) = pure $ RV fc (RCLoc (lookupEnv idx env))
    normalize env (LAppName fc lazy n args) =
        bindMany env args (\locs => pure $ RAppName fc lazy n locs)
    normalize env (LUnderApp fc n missing args) =
        bindMany env args (\locs => pure $ RUnderApp fc n missing locs)
    normalize env (LApp fc lazy c a) =
        bindOne env c (\cl => bindOne env a (\al => pure $ RApp fc lazy cl al))
    normalize env (LLet fc x val body) = do
        i <- nextVarId
        valRC <- normalize env val
        let rep = maybe RBoxed RNative (repOf valRC)
        bodyRC <- normalize (i :: env) body
        pure $ RLet fc i rep valRC bodyRC
    normalize env (LCon fc n ci tag args) =
        -- reuseFrom is always Nothing here -- Compiler.RC2.Reuse fills
        -- it in as its own dedicated pass, after Phase 1 and 2 are both
        -- done (see RCExp.idr's own doc comment on RCon).
        bindMany env args (\locs => pure $ RCon fc n ci tag locs Nothing)
    normalize env (LOp fc lazy op args) =
        -- postDrop is always [] here -- Phase 2 (`annotate`) fills it in
        -- once ownership is known (see RCExp.idr's ROp doc comment).
        bindManyV env args (\locs => pure $ ROp fc lazy op locs [])
    normalize env (LExtPrim fc lazy p args) =
        bindMany env args (\locs => pure $ RExtPrim fc lazy p locs)
    normalize env (LConCase fc sc alts mDef) =
        bindOne env sc (\scl => do
            alts' <- traverse (normalizeConAlt env) alts
            mDef' <- traverseOpt (normalize env) mDef
            pure $ RConCase fc scl alts' mDef')
    normalize env (LConstCase fc sc alts mDef) = do
        fused <- tryFuseCompare env sc alts mDef
        case fused of
             Just e => pure e
             Nothing =>
                 bindOne env sc (\scl => do
                     alts' <- traverse (normalizeConstAlt env) alts
                     mDef' <- traverseOpt (normalize env) mDef
                     pure $ RConstCase fc scl alts' mDef')
    normalize env (LPrimVal fc c) = pure $ RPrimVal fc c
    normalize env (LErased fc) = pure $ RErased fc
    normalize env (LCrash fc msg) = pure $ RCrash fc msg

    normalizeConAlt : {auto v : Ref NextVar Int} ->
                       Env -> LiftedConAlt vars -> Core RConAlt
    normalizeConAlt env (MkLConAlt n ci tag args body) = do
        argIds <- traverse (const nextVarId) args
        bodyRC <- normalize (argIds ++ env) body
        pure $ MkRConAlt n ci tag argIds bodyRC Nothing

    normalizeConstAlt : {auto v : Ref NextVar Int} ->
                         Env -> LiftedConstAlt vars -> Core RConstAlt
    normalizeConstAlt env (MkLConstAlt c body) = MkRConstAlt c <$> normalize env body

    ||| Shared body for each `tryFuseCompare` clause below -- factored out
    ||| so the arity-2 refinement each specific comparison constructor
    ||| brings (matched directly in the caller's own pattern, not via
    ||| `Types.cmpArgTy`'s arity-generic signature, precisely so `op`'s
    ||| arity unifies with `args`'s length automatically) only has to be
    ||| written once.
    tryFuseCompareOp : {auto v : Ref NextVar Int} ->
                        Env -> FC -> PrimFn 2 -> PrimType -> Vect 2 (Lifted vars) ->
                        List (LiftedConstAlt vars) -> Maybe (Lifted vars) -> Core (Maybe RCExp)
    tryFuseCompareOp env fc op ty args alts mDef =
        if not (nativeEligible ty)
           then pure Nothing
           else case boolBranches alts mDef of
                     Nothing => pure Nothing
                     Just (trueL, falseL) => do
                         trueRC <- normalize env trueL
                         falseRC <- normalize env falseL
                         Just <$> bindManyV env args (\locs => pure $ RCmpCase fc op locs [] trueRC falseRC)

    ||| If `sc` is a native-eligible boolean comparison (LT/GT/EQ/LTE/
    ||| GTE) and `alts`/`mDef` together form a two-way match on Idris2's
    ||| own Bool encoding (`boolBranches`), fuse the whole thing directly
    ||| into an `RCmpCase`: neither the comparison's Boxed Bool result
    ||| nor the scrutinee variable `bindOne` would otherwise introduce
    ||| ever gets materialised. `Nothing` leaves `normalize`'s
    ||| `LConstCase` case to fall through to its ordinary, unfused
    ||| handling.
    tryFuseCompare : {auto v : Ref NextVar Int} ->
                      Env -> Lifted vars -> List (LiftedConstAlt vars) -> Maybe (Lifted vars) ->
                      Core (Maybe RCExp)
    tryFuseCompare env (LOp fc lazy (LT ty) args) alts mDef = tryFuseCompareOp env fc (LT ty) ty args alts mDef
    tryFuseCompare env (LOp fc lazy (GT ty) args) alts mDef = tryFuseCompareOp env fc (GT ty) ty args alts mDef
    tryFuseCompare env (LOp fc lazy (EQ ty) args) alts mDef = tryFuseCompareOp env fc (EQ ty) ty args alts mDef
    tryFuseCompare env (LOp fc lazy (LTE ty) args) alts mDef = tryFuseCompareOp env fc (LTE ty) ty args alts mDef
    tryFuseCompare env (LOp fc lazy (GTE ty) args) alts mDef = tryFuseCompareOp env fc (GTE ty) ty args alts mDef
    tryFuseCompare _ _ _ _ = pure Nothing

||| args ordering matches Compiler.LambdaLift.MkLFun's own documented
||| convention: the emitted function takes `args` first, then `reverse
||| scope` (`scope` is the set of enclosing free variables a lifted-out
||| closure body captures; empty for genuine top-level definitions).
normalizeDef : LiftedDef -> Core RCDef
normalizeDef (MkLFun args scope body) = do
    v <- newRef NextVar 0
    argIds <- traverse (const (nextVarId {v})) args
    scopeIds <- traverse (const (nextVarId {v})) scope
    let env = scopeIds ++ argIds
    bodyRC <- normalize {v} env body
    pure $ MkRCFun (argIds ++ reverse scopeIds) bodyRC
normalizeDef (MkLCon tag arity nt) = pure $ MkRCCon tag arity nt
normalizeDef (MkLForeign ccs fargs ret) = pure $ MkRCForeign ccs fargs ret
normalizeDef (MkLError body) = do
    v <- newRef NextVar 0
    MkRCError <$> normalize {v} [] body

------------------------------------------------------------------------
-- Phase 2: reference-counting annotation (RCExp -> RCExp)
--
-- Ownership bookkeeping (what's "owned" vs. still needed later, so must be
-- borrowed) is unchanged from the original design; the only difference is
-- that a borrow now materialises as an explicit `RDup` node wrapping the
-- consuming expression, instead of a flag on the occurrence.

Owned : Type
Owned = SortedSet RCLocal

dropUnusedOwnedVars : Owned -> SortedSet RCLocal -> (List RCLocal, Owned)
dropUnusedOwnedVars owned usedVars =
    let actualOwned = intersection owned usedVars in
    let shouldDrop = difference owned actualOwned in
    (Prelude.toList shouldDrop, actualOwned)

||| Wrap `e` in an RDup for each variable in `needed` (order doesn't
||| matter between independent increments).
wrapDups : FC -> List RCLocal -> RCExp -> RCExp
wrapDups fc needed e = foldr (RDup fc) e needed

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

||| Wrap `body` in the cleanup for a single dead variable: an unconditional
||| `RFree` if `value` (its birthplace) is a provably-unshared fresh
||| allocation, otherwise the ordinary checked `RDrop`. Never wraps at all
||| for a native (unboxed, unrefcounted) local, or for a Boxed local
||| that's in `natives` anyway (alwaysUnboxedBoxedLocalsR -- see its own
||| comment for why that's just as unconditionally a no-op).
dropDeadLet : FC -> SortedSet RCLocal -> Rep -> RCLocal -> RCExp -> RCExp -> RCExp
dropDeadLet fc natives (RNative _) _ _ body = body
dropDeadLet fc natives RBoxed loc value body =
    if contains loc natives
       then body
       else if freeableShape value
               then RFree fc loc body
               else RDrop fc [loc] body

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
         RNative _ => insert (RCLoc var) vs
         RBoxed => vs
nativeLocalsR (RConCase _ _ alts mDef) =
    let altsNs = map (\(MkRConAlt _ _ _ _ body _) => nativeLocalsR body) alts in
    concat $ maybe altsNs (\d => nativeLocalsR d :: altsNs) mDef
nativeLocalsR (RConstCase _ _ alts mDef) =
    let altsNs = map (\(MkRConstAlt _ body) => nativeLocalsR body) alts in
    concat $ maybe altsNs (\d => nativeLocalsR d :: altsNs) mDef
nativeLocalsR (RCmpCase _ _ _ _ t f) = union (nativeLocalsR t) (nativeLocalsR f)
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
||| be unconditional no-ops (support/rc2/datatypes.h), so generating the
||| calls at all is pure waste. Operates on Phase 1's output, same as
||| nativeLocalsR and for the same reason.
alwaysUnboxedBoxedLocalsR : RCExp -> SortedSet RCLocal
alwaysUnboxedBoxedLocalsR (RLet _ _ _ value body) =
    union (alwaysUnboxedBoxedLocalsR value) (alwaysUnboxedBoxedLocalsR body)
alwaysUnboxedBoxedLocalsR (ROp _ _ op args _) =
    case opResultRep op of
         Nothing => empty
         Just ty => if alwaysUnboxed (opArgTyFor ty op)
                       then fromList (filter isRealLoc (toList args))
                       else empty
  where
    isRealLoc : RCLocal -> Bool
    isRealLoc (RCLoc _) = True
    isRealLoc _ = False
alwaysUnboxedBoxedLocalsR (RConCase _ _ alts mDef) =
    let altsNs = map (\(MkRConAlt _ _ _ _ body _) => alwaysUnboxedBoxedLocalsR body) alts in
    concat $ maybe altsNs (\d => alwaysUnboxedBoxedLocalsR d :: altsNs) mDef
alwaysUnboxedBoxedLocalsR (RConstCase _ _ alts mDef) =
    let altsNs = map (\(MkRConstAlt _ body) => alwaysUnboxedBoxedLocalsR body) alts in
    concat $ maybe altsNs (\d => alwaysUnboxedBoxedLocalsR d :: altsNs) mDef
alwaysUnboxedBoxedLocalsR (RCmpCase _ op args _ t f) =
    let ownNs = case cmpArgTy op of
                     Nothing => empty
                     Just ty => if alwaysUnboxed ty
                                   then fromList (filter isRealLoc (toList args))
                                   else empty
    in union ownNs (union (alwaysUnboxedBoxedLocalsR t) (alwaysUnboxedBoxedLocalsR f))
  where
    isRealLoc : RCLocal -> Bool
    isRealLoc (RCLoc _) = True
    isRealLoc _ = False
alwaysUnboxedBoxedLocalsR _ = empty

||| Which of `vars` need a dup: thread (and shrink) `owned` exactly as
||| before -- the *first* occurrence of an owned variable moves it (no dup
||| needed), any later occurrence (or one that was never owned to begin
||| with) needs a dup -- except a `natives`-listed local, which never needs
||| a dup (or any refcount op at all) no matter how it's used. An
||| `RCConst` is skipped the same way as a native -- it was never a real
||| heap value to begin with (see RCExp.idr's module note on RCLocal).
splitBorrows : (natives : SortedSet RCLocal) -> Owned -> List RCLocal -> List RCLocal
splitBorrows _ _ [] = []
splitBorrows natives owned (RCConst _ :: vars) = splitBorrows natives owned vars
splitBorrows natives owned (v :: vars) =
    if contains v natives
        then splitBorrows natives owned vars
        else if contains v owned
                then splitBorrows natives (delete v owned) vars
                else v :: splitBorrows natives owned vars

splitBorrowsV : (natives : SortedSet RCLocal) -> Owned -> Vect n RCLocal -> List RCLocal
splitBorrowsV natives owned = splitBorrows natives owned . toList

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
    isBoxedOperand v = not (contains v natives)

mutual
    branchBody : SortedSet RCLocal -> Owned -> SortedSet RCLocal -> RCExp -> Core RCExp
    branchBody natives owned ownedWithArgs body = do
        let (shouldDrop, actualOwned) = dropUnusedOwnedVars ownedWithArgs (freeLocalsR body)
        rest <- annotate natives actualOwned body
        pure $ case shouldDrop of
                    [] => rest
                    _  => RDrop emptyFC shouldDrop rest

    annotate : SortedSet RCLocal -> Owned -> RCExp -> Core RCExp
    annotate natives owned (RV fc v) =
        pure $ if contains v natives || contains v owned then RV fc v else RDup fc v (RV fc v)
    annotate natives owned (RAppName fc lazy n args) =
        pure $ wrapDups fc (splitBorrows natives owned args) (RAppName fc lazy n args)
    annotate natives owned (RUnderApp fc n missing args) =
        pure $ wrapDups fc (splitBorrows natives owned args) (RUnderApp fc n missing args)
    annotate natives owned (RApp fc lazy c a) =
        pure $ wrapDups fc (splitBorrows natives owned [c, a]) (RApp fc lazy c a)
    annotate natives owned (RLet fc var rep value body) = do
        let usedVars = freeLocalsR body
        let borrowVal = intersection owned (delete (RCLoc var) usedVars)
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
        let bodyRC' = if contains (RCLoc var) usedVars
                         then bodyRC
                         else dropDeadLet fc natives rep (RCLoc var) valueRC bodyRC
        pure $ RLet fc var rep valueRC bodyRC'
    annotate natives owned (RCon fc n ci tag args _) =
        -- reuseFrom stays Nothing -- Compiler.RC2.Reuse decides that in
        -- its own pass, after annotate is completely done (it needs the
        -- final RDrop lists this function produces, see its own module
        -- note).
        pure $ wrapDups fc (splitBorrows natives owned args) (RCon fc n ci tag args Nothing)
    annotate natives owned (ROp fc lazy op args _) =
        pure $ wrapDups fc (splitBorrowsV natives owned args)
                          (ROp fc lazy op args (boxedOperands natives (toList args)))
    annotate natives owned (RExtPrim fc lazy p args) = pure $ RExtPrim fc lazy p args
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
        t' <- branchBody natives ownedForBranches ownedForBranches t
        f' <- branchBody natives ownedForBranches ownedForBranches f
        pure $ wrapDups fc (splitBorrowsV natives (owned `difference` liveArgs) args)
                          (RCmpCase fc op args (boxedOperands natives (toList args)) t' f')
    annotate natives owned (RConCase fc sc alts mDef) = do
        alts' <- traverse (annotateConAlt natives owned sc) alts
        mDef' <- traverseOpt (branchBody natives owned owned) mDef
        pure $ RConCase fc sc alts' mDef'
    annotate natives owned (RConstCase fc sc alts mDef) = do
        alts' <- traverse (annotateConstAlt natives owned) alts
        mDef' <- traverseOpt (branchBody natives owned owned) mDef
        pure $ RConstCase fc sc alts' mDef'
    annotate natives owned (RPrimVal fc c) = pure $ RPrimVal fc c
    annotate natives owned (RErased fc) = pure $ RErased fc
    annotate natives owned (RCrash fc msg) = pure $ RCrash fc msg
    annotate natives owned (RDup fc v body) = RDup fc v <$> annotate natives owned body
    annotate natives owned (RDrop fc vars body) = RDrop fc vars <$> annotate natives owned body
    annotate natives owned (RFree fc v body) = RFree fc v <$> annotate natives owned body
    -- Never actually produced until Compiler.RC2.Reuse runs, which is
    -- strictly after annotate is done with the whole definition -- kept
    -- total (as a plain pass-through) rather than assuming that can
    -- never change.
    annotate natives owned (RReleaseReuse fc v body) = RReleaseReuse fc v <$> annotate natives owned body

    annotateConAlt : SortedSet RCLocal -> Owned -> RCLocal -> RConAlt -> Core RConAlt
    annotateConAlt natives owned sc (MkRConAlt name ci tag args body _) = do
        -- Matching NIL/NOTHING/ZERO/UNIT consumes `sc` itself (it was only
        -- ever a NULL check, no heap object to keep owning).
        let erased = ci == NIL || ci == NOTHING || ci == ZERO || ci == UNIT
        -- `natives`-listed fields (e.g. an Int8 field extracted from a
        -- constructor and later read in an arithmetic op) don't belong
        -- in `owned` either, same reasoning as RLet's owned' above.
        let ownedWithArgs = union (fromList (RCLoc <$> args) `difference` natives)
                                   (if erased then delete sc owned else owned)
        bodyRC <- branchBody natives owned ownedWithArgs body
        -- offersReuse stays Nothing -- Compiler.RC2.Reuse decides that
        -- afterward, using the RDrop list this produces (see its own
        -- module note).
        pure $ MkRConAlt name ci tag args bodyRC Nothing

    annotateConstAlt : SortedSet RCLocal -> Owned -> RConstAlt -> Core RConstAlt
    annotateConstAlt natives owned (MkRConstAlt c body) = MkRConstAlt c <$> branchBody natives owned owned body

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
annotateDef (MkRCFun args body) = do
    let natives = definitionNatives body
    -- `natives`-listed args (see definitionNatives) don't belong in
    -- `owned` either -- same reasoning as RLet's owned' above -- so
    -- they're excluded before dropUnusedOwnedVars ever sees them,
    -- rather than relying on it to notice they're unused later (they
    -- may well be used, just never via anything owned/dup/drop cares
    -- about).
    let argsVars = fromList (RCLoc <$> args) `difference` natives
    let (shouldDrop, actualOwned) = dropUnusedOwnedVars argsVars (freeLocalsR body)
    rest <- annotate natives actualOwned body
    pure $ MkRCFun args $ case shouldDrop of
                               [] => rest
                               _  => RDrop emptyFC shouldDrop rest
annotateDef d@(MkRCCon _ _ _) = pure d
annotateDef d@(MkRCForeign _ _ _) = pure d
annotateDef (MkRCError body) = MkRCError <$> annotate (definitionNatives body) empty body

export
toRCDef : LiftedDef -> Core RCDef
toRCDef ld = normalizeDef ld >>= annotateDef
