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
-- and stored directly on the RLet node. Ownership (dup/drop) is not yet
-- decided at this point: every RCVar.borrowed is a placeholder.
--
-- Phase 2 (`annotate`) walks that shape and rebuilds it with the actual
-- ownership decisions (borrow vs. move) and explicit RDrop insertions,
-- mirroring RC2's original borrow/ownership algorithm (see RCExp.idr's
-- module note) -- just retargeted from ANF onto our own IR. It threads
-- each RLet's `Rep` straight through unchanged (Phase 1 already decided
-- it; ownership doesn't affect it).

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

dummy : RCLocal -> RCVar
dummy l = MkRCVar l False

mutual
    ||| Normalise a single (possibly compound) sub-expression: if it's
    ||| already trivial (a local/erased), no new binding is needed;
    ||| otherwise let-bind it to a fresh local first.
    bindOne : {auto v : Ref NextVar Int} ->
              Env -> Lifted vars -> (RCLocal -> Core RCExp) -> Core RCExp
    bindOne env (LLocal {idx} fc p) k = k (RCLoc (lookupEnv idx env))
    bindOne env (LErased fc) k = k RCNull
    bindOne env e k
        = do i <- nextVarId
             eRC <- normalize env e
             let rep = maybe RBoxed RNative (repOf eRC)
             rest <- k (RCLoc i)
             pure $ RLet (getFC e) i rep eRC rest False

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
    normalize env (LLocal {idx} fc p) = pure $ RV fc (dummy (RCLoc (lookupEnv idx env)))
    normalize env (LAppName fc lazy n args) =
        bindMany env args (\locs => pure $ RAppName fc lazy n (map dummy locs))
    normalize env (LUnderApp fc n missing args) =
        bindMany env args (\locs => pure $ RUnderApp fc n missing (map dummy locs))
    normalize env (LApp fc lazy c a) =
        bindOne env c (\cl => bindOne env a (\al => pure $ RApp fc lazy (dummy cl) (dummy al)))
    normalize env (LLet fc x val body) = do
        i <- nextVarId
        valRC <- normalize env val
        let rep = maybe RBoxed RNative (repOf valRC)
        bodyRC <- normalize (i :: env) body
        pure $ RLet fc i rep valRC bodyRC False
    normalize env (LCon fc n ci tag args) =
        bindMany env args (\locs => pure $ RCon fc n ci tag (map dummy locs))
    normalize env (LOp fc lazy op args) =
        bindManyV env args (\locs => pure $ ROp fc lazy op (map dummy locs))
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
-- Phase 2: ownership annotation (RCExp -> RCExp)

Owned : Type
Owned = SortedSet RCLocal

moveFromOwnedToBorrowed : Owned -> SortedSet RCLocal -> Owned
moveFromOwnedToBorrowed owned vars = owned `difference` vars

dropUnusedOwnedVars : Owned -> SortedSet RCLocal -> (List RCLocal, Owned)
dropUnusedOwnedVars owned usedVars =
    let actualOwned = intersection owned usedVars in
    let shouldDrop = difference owned actualOwned in
    (Prelude.toList shouldDrop, actualOwned)

annotVar : Owned -> RCLocal -> RCVar
annotVar owned l = MkRCVar l (not (contains l owned))

annotVars : Owned -> List RCLocal -> List RCVar
annotVars _ [] = []
annotVars owned (v :: vars) =
    if contains v owned
        then MkRCVar v False :: annotVars (delete v owned) vars
        else MkRCVar v True :: annotVars owned vars

annotVarsVect : Owned -> Vect n RCLocal -> Vect n RCVar
annotVarsVect _ [] = []
annotVarsVect owned (v :: vars) =
    let owned' = if contains v owned then delete v owned else owned
    in annotVar owned v :: annotVarsVect owned' vars

mutual
    branchBody : Owned -> SortedSet RCLocal -> RCExp -> Core RCExp
    branchBody owned ownedWithArgs body = do
        let (shouldDrop, actualOwned) = dropUnusedOwnedVars ownedWithArgs (freeLocalsR body)
        rest <- annotate actualOwned body
        pure $ case shouldDrop of
                    [] => rest
                    _  => RDrop emptyFC shouldDrop rest

    annotate : Owned -> RCExp -> Core RCExp
    annotate owned (RV fc v) = pure $ RV fc (annotVar owned v.rcVar)
    annotate owned (RAppName fc lazy n args) =
        pure $ RAppName fc lazy n (annotVars owned (map rcVar args))
    annotate owned (RUnderApp fc n missing args) =
        pure $ RUnderApp fc n missing (annotVars owned (map rcVar args))
    annotate owned (RApp fc lazy c a) =
        case annotVars owned [c.rcVar, a.rcVar] of
             [c', a'] => pure $ RApp fc lazy c' a'
             _ => pure $ RCrash fc "Can't happen (RApp)"
    annotate owned (RLet fc var rep value body _) = do
        let usedVars = freeLocalsR body
        let borrowVal = intersection owned (delete (RCLoc var) usedVars)
        let owned' = if contains (RCLoc var) usedVars then insert (RCLoc var) borrowVal else borrowVal
        valueRC <- annotate (owned `difference` borrowVal) value
        bodyRC <- annotate owned' body
        pure $ RLet fc var rep valueRC bodyRC (not (contains (RCLoc var) usedVars))
    annotate owned (RCon fc n ci tag args) =
        pure $ RCon fc n ci tag (annotVars owned (map rcVar args))
    annotate owned (ROp fc lazy op args) =
        pure $ ROp fc lazy op (annotVarsVect owned (map rcVar args))
    annotate owned (RExtPrim fc lazy p args) = pure $ RExtPrim fc lazy p args
    annotate owned (RConCase fc sc alts mDef) = do
        alts' <- traverse (annotateConAlt owned sc) alts
        mDef' <- traverseOpt (branchBody owned owned) mDef
        pure $ RConCase fc sc alts' mDef'
    annotate owned (RConstCase fc sc alts mDef) = do
        alts' <- traverse (annotateConstAlt owned) alts
        mDef' <- traverseOpt (branchBody owned owned) mDef
        pure $ RConstCase fc sc alts' mDef'
    annotate owned (RPrimVal fc c) = pure $ RPrimVal fc c
    annotate owned (RErased fc) = pure $ RErased fc
    annotate owned (RCrash fc msg) = pure $ RCrash fc msg
    annotate owned (RDrop fc vars body) = RDrop fc vars <$> annotate owned body

    annotateConAlt : Owned -> RCLocal -> RConAlt -> Core RConAlt
    annotateConAlt owned sc (MkRConAlt name ci tag args body) = do
        -- Matching NIL/NOTHING/ZERO/UNIT consumes `sc` itself (it was only
        -- ever a NULL check, no heap object to keep owning).
        let erased = ci == NIL || ci == NOTHING || ci == ZERO || ci == UNIT
        let ownedWithArgs = union (fromList (RCLoc <$> args)) (if erased then delete sc owned else owned)
        bodyRC <- branchBody owned ownedWithArgs body
        pure $ MkRConAlt name ci tag args bodyRC

    annotateConstAlt : Owned -> RConstAlt -> Core RConstAlt
    annotateConstAlt owned (MkRConstAlt c body) = MkRConstAlt c <$> branchBody owned owned body

annotateDef : RCDef -> Core RCDef
annotateDef (MkRCFun args body) = do
    let argsVars = fromList (RCLoc <$> args)
    let (shouldDrop, actualOwned) = dropUnusedOwnedVars argsVars (freeLocalsR body)
    rest <- annotate actualOwned body
    pure $ MkRCFun args $ case shouldDrop of
                               [] => rest
                               _  => RDrop emptyFC shouldDrop rest
annotateDef d@(MkRCCon _ _ _) = pure d
annotateDef d@(MkRCForeign _ _ _) = pure d
annotateDef (MkRCError body) = MkRCError <$> annotate empty body

export
toRCDef : LiftedDef -> Core RCDef
toRCDef ld = normalizeDef ld >>= annotateDef
