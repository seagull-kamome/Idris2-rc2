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
        bindMany env args (\locs => pure $ RCon fc n ci tag locs)
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
    normalize env (LConstCase fc sc alts mDef) =
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
        pure $ MkRConAlt n ci tag argIds bodyRC

    normalizeConstAlt : {auto v : Ref NextVar Int} ->
                         Env -> LiftedConstAlt vars -> Core RConstAlt
    normalizeConstAlt env (MkLConstAlt c body) = MkRConstAlt c <$> normalize env body

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
freeableShape (RCon _ _ ci _ _) = ci /= NIL && ci /= NOTHING && ci /= ZERO && ci /= UNIT
freeableShape (RUnderApp _ _ _ _) = True
freeableShape _ = False

||| Wrap `body` in the cleanup for a single dead variable: an unconditional
||| `RFree` if `value` (its birthplace) is a provably-unshared fresh
||| allocation, otherwise the ordinary checked `RDrop`. Never wraps at all
||| for a native (unboxed, unrefcounted) local.
dropDeadLet : FC -> Rep -> RCLocal -> RCExp -> RCExp -> RCExp
dropDeadLet fc (RNative _) _ _ body = body
dropDeadLet fc RBoxed loc value body =
    if freeableShape value
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
    let altsNs = map (\(MkRConAlt _ _ _ _ body) => nativeLocalsR body) alts in
    concat $ maybe altsNs (\d => nativeLocalsR d :: altsNs) mDef
nativeLocalsR (RConstCase _ _ alts mDef) =
    let altsNs = map (\(MkRConstAlt _ body) => nativeLocalsR body) alts in
    concat $ maybe altsNs (\d => nativeLocalsR d :: altsNs) mDef
nativeLocalsR _ = empty

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
        -- Never add a Native local to `owned` -- it has no refcount to
        -- own/borrow/drop in the first place (see `splitBorrows`/`RV`
        -- above, which are the ones that actually decide whether a use
        -- needs a dup; this just keeps `owned` itself Boxed-only, which
        -- `dropUnusedOwnedVars`/`branchBody` rely on).
        let owned' = case rep of
                          RNative _ => borrowVal
                          RBoxed => if contains (RCLoc var) usedVars then insert (RCLoc var) borrowVal else borrowVal
        valueRC <- annotate natives (owned `difference` borrowVal) value
        bodyRC <- annotate natives owned' body
        let bodyRC' = if contains (RCLoc var) usedVars
                         then bodyRC
                         else dropDeadLet fc rep (RCLoc var) valueRC bodyRC
        pure $ RLet fc var rep valueRC bodyRC'
    annotate natives owned (RCon fc n ci tag args) =
        pure $ wrapDups fc (splitBorrows natives owned args) (RCon fc n ci tag args)
    annotate natives owned (ROp fc lazy op args _) =
        pure $ wrapDups fc (splitBorrowsV natives owned args)
                          (ROp fc lazy op args (boxedOperands natives (toList args)))
    annotate natives owned (RExtPrim fc lazy p args) = pure $ RExtPrim fc lazy p args
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

    annotateConAlt : SortedSet RCLocal -> Owned -> RCLocal -> RConAlt -> Core RConAlt
    annotateConAlt natives owned sc (MkRConAlt name ci tag args body) = do
        -- Matching NIL/NOTHING/ZERO/UNIT consumes `sc` itself (it was only
        -- ever a NULL check, no heap object to keep owning).
        let erased = ci == NIL || ci == NOTHING || ci == ZERO || ci == UNIT
        let ownedWithArgs = union (fromList (RCLoc <$> args)) (if erased then delete sc owned else owned)
        bodyRC <- branchBody natives owned ownedWithArgs body
        pure $ MkRConAlt name ci tag args bodyRC

    annotateConstAlt : SortedSet RCLocal -> Owned -> RConstAlt -> Core RConstAlt
    annotateConstAlt natives owned (MkRConstAlt c body) = MkRConstAlt c <$> branchBody natives owned owned body

annotateDef : RCDef -> Core RCDef
annotateDef (MkRCFun args body) = do
    let natives = nativeLocalsR body
    let argsVars = fromList (RCLoc <$> args)
    let (shouldDrop, actualOwned) = dropUnusedOwnedVars argsVars (freeLocalsR body)
    rest <- annotate natives actualOwned body
    pure $ MkRCFun args $ case shouldDrop of
                               [] => rest
                               _  => RDrop emptyFC shouldDrop rest
annotateDef d@(MkRCCon _ _ _) = pure d
annotateDef d@(MkRCForeign _ _ _) = pure d
annotateDef (MkRCError body) = MkRCError <$> annotate (nativeLocalsR body) empty body

export
toRCDef : LiftedDef -> Core RCDef
toRCDef ld = normalizeDef ld >>= annotateDef
