||| Lambda lifting of upstream's `NamedCExp`, in place of
||| `Compiler.LambdaLift`, so that rc2 owns the step where closures lose
||| their place in the enclosing code. Its output is what upstream's
||| lifting gives with `doLazyAnnots = False`. Design:
||| `rc2/doc/lambda-lifting.md`.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
|||
||| The capture analysis (`Used` to `dropUnused`) is copied from
||| `idris2-src/src/Compiler/LambdaLift.idr`, where it is private:
||| Copyright (c) 2020 Edwin Brady, BSD-3-Clause (idris2-src/LICENSE).
module Compiler.RC2.LambdaLift

import Compiler.Common
import Compiler.LambdaLift
import Core.CompileExpr
import Core.Context
import Core.TT

import Data.SortedMap
import Data.Vect

import Libraries.Data.List.Extra
import Libraries.Data.SnocList.SizeOf

%default covering

-------------------------------------------------------------------------------
-- Capture analysis, from upstream

unload : FC -> (lazy : Maybe LazyReason) -> Lifted vars -> List (Lifted vars) -> Core (Lifted vars)
unload fc _ f [] = pure f
-- only outermost LApp must be lazy as rest will be closures
unload fc lazy f (a :: as) = unload fc Nothing (LApp fc lazy f a) as

record Used (vars : Scope) where
  constructor MkUsed
  used : Vect (length vars) Bool

initUsed : {vars : _} -> Used vars
initUsed {vars} = MkUsed (replicate (length vars) False)

weakenUsed : {outer : _} -> Used vars -> Used (outer ++ vars)
weakenUsed {outer} (MkUsed xs) =
  MkUsed (rewrite lengthDistributesOverAppend outer vars in
         (replicate (length outer) False ++ xs))

contractUsed : (Used (x::vars)) -> Used vars
contractUsed (MkUsed xs) = MkUsed (tail xs)

contractUsedMany : {remove : _} ->
                   (Used (remove ++ vars)) ->
                   Used vars
contractUsedMany {remove=[]} x = x
contractUsedMany {remove=(r::rs)} x = contractUsedMany {remove=rs} (contractUsed x)

markUsed : {vars : _} ->
           (idx : Nat) ->
           {0 prf : IsVar x idx vars} ->
           Used vars ->
           Used vars
markUsed {vars} {prf} idx (MkUsed us) =
  let newUsed = replaceAt (finIdx prf) True us in
  MkUsed newUsed
    where
    finIdx : {vars : _} -> {idx : _} ->
             (0 prf : IsVar x idx vars) ->
             Fin (length vars)
    finIdx {idx=Z} First = FZ
    finIdx {idx=S x} (Later l) = FS (finIdx l)

getUnused : Used vars ->
            Vect (length vars) Bool
getUnused (MkUsed uv) = map not uv

total
dropped : (vars : Scope) ->
          (drop : Vect (length vars) Bool) ->
          Scope
dropped [] _ = []
dropped (x::xs) (False::us) = x::(dropped xs us)
dropped (x::xs) (True::us) = dropped xs us

usedVars : {vars : _} ->
           Used vars ->
           Lifted vars ->
           Used vars
usedVars used (LLocal {idx} fc prf) =
  markUsed {prf} idx used
usedVars used (LAppName fc lazy n args) =
  foldl (usedVars {vars}) used args
usedVars used (LUnderApp fc n miss args) =
  foldl (usedVars {vars}) used args
usedVars used (LApp fc lazy c arg) =
  usedVars (usedVars used arg) c
usedVars used (LLet fc x val sc) =
  let innerUsed = contractUsed $ usedVars (weakenUsed {outer=Scope.single x} used) sc in
      usedVars innerUsed val
usedVars used (LCon fc n ci tag args) =
  foldl (usedVars {vars}) used args
usedVars used (LOp fc lazy fn args) =
  foldl (usedVars {vars}) used args
usedVars used (LExtPrim fc lazy fn args) =
  foldl (usedVars {vars}) used args
usedVars used (LConCase fc sc alts def) =
    let defUsed = maybe used (usedVars used {vars}) def
        scDefUsed = usedVars defUsed sc in
        foldl usedConAlt scDefUsed alts
  where
    usedConAlt : {default Nothing lazy : Maybe LazyReason} ->
                  Used vars -> LiftedConAlt vars -> Used vars
    usedConAlt used (MkLConAlt n ci tag args sc) =
      contractUsedMany {remove=args} (usedVars (weakenUsed used) sc)

usedVars used (LConstCase fc sc alts def) =
    let defUsed = maybe used (usedVars used {vars}) def
        scDefUsed = usedVars defUsed sc in
        foldl usedConstAlt scDefUsed alts
  where
    usedConstAlt : {default Nothing lazy : Maybe LazyReason} ->
                    Used vars -> LiftedConstAlt vars -> Used vars
    usedConstAlt used (MkLConstAlt c sc) = usedVars used sc
usedVars used (LPrimVal {}) = used
usedVars used (LErased {})  = used
usedVars used (LCrash {})   = used

dropIdx : {vars : _} ->
          {idx : _} ->
          (outer : Scope) ->
          (unused : Vect (length vars) Bool) ->
          (0 p : IsVar x idx (outer ++ vars)) ->
          Var (outer ++ (dropped vars unused))
dropIdx [] (False::_) First = first
dropIdx [] (True::_) First = assert_total $
  idris_crash "INTERNAL ERROR: Referenced variable marked as unused"
dropIdx [] (False::rest) (Later p) = Var.later $ dropIdx Scope.empty rest p
dropIdx [] (True::rest) (Later p) = dropIdx Scope.empty rest p
dropIdx (_::xs) unused First = first
dropIdx (_::xs) unused (Later p) = Var.later $ dropIdx xs unused p

dropUnused : {vars : _} ->
             {outer : Scope} ->
             (unused : Vect (length vars) Bool) ->
             (l : Lifted (outer ++ vars)) ->
             Lifted (outer ++ (dropped vars unused))
dropUnused _ (LPrimVal fc val) = LPrimVal fc val
dropUnused _ (LErased fc) = LErased fc
dropUnused _ (LCrash fc msg) = LCrash fc msg
dropUnused {outer} unused (LLocal fc p) =
  let (MkVar p') = dropIdx outer unused p in LLocal fc p'
dropUnused unused (LCon fc n ci tag args) =
  let args' = map (dropUnused unused) args in
      LCon fc n ci tag args'
dropUnused {outer} unused (LLet fc n val sc) =
  let val' = dropUnused unused val
      sc' = dropUnused {outer=n::outer} (unused) sc in
      LLet fc n val' sc'
dropUnused unused (LApp fc lazy c arg) =
  let c' = dropUnused unused c
      arg' = dropUnused unused arg in
      LApp fc lazy c' arg'
dropUnused unused (LOp fc lazy fn args) =
  let args' = map (dropUnused unused) args in
      LOp fc lazy fn args'
dropUnused unused (LExtPrim fc lazy n args) =
  let args' = map (dropUnused unused) args in
      LExtPrim fc lazy n args'
dropUnused unused (LAppName fc lazy n args) =
  let args' = map (dropUnused unused) args in
      LAppName fc lazy n args'
dropUnused unused (LUnderApp fc n miss args) =
  let args' = map (dropUnused unused) args in
      LUnderApp fc n miss args'
dropUnused {vars} {outer} unused (LConCase fc sc alts def) =
  let alts' = map dropConCase alts in
      LConCase fc (dropUnused unused sc) alts' (map (dropUnused unused) def)
  where
    dropConCase : LiftedConAlt (outer ++ vars) ->
                  LiftedConAlt (outer ++ (dropped vars unused))
    dropConCase (MkLConAlt n ci t args sc) =
      let sc' = (rewrite sym $ appendAssociative args outer vars in sc)
          droppedSc = dropUnused {vars=vars} {outer=args++outer} unused sc' in
      MkLConAlt n ci t args (rewrite appendAssociative args outer (dropped vars unused) in droppedSc)
dropUnused {vars} {outer} unused (LConstCase fc sc alts def) =
  let alts' = map dropConstCase alts in
      LConstCase fc (dropUnused unused sc) alts' (map (dropUnused unused) def)
  where
    dropConstCase : LiftedConstAlt (outer ++ vars) ->
                    LiftedConstAlt (outer ++ (dropped vars unused))
    dropConstCase (MkLConstAlt c val) = MkLConstAlt c (dropUnused unused val)

-------------------------------------------------------------------------------
-- What lifting loses, kept per lifted definition

public export
data LiftOrigin = FromLambda | FromDelay LazyReason

||| A lifted definition's source: the top-level definition it was lifted
||| out of, whether it was a lambda or a `Delay`, and how many
||| parameters of its own it takes (after the captured ones). A `Delay`
||| of a lambda is merged with it, so it can take more than one.
public export
record LiftInfo where
  constructor MkLiftInfo
  parent : Name
  origin : LiftOrigin
  params : Nat

-------------------------------------------------------------------------------
-- Lifting

data Lifts : Type where

record LiftState where
  constructor MkLiftState
  basename : Name
  lifted : List (Name, LiftedDef)
  infos : List (Name, LiftInfo)
  nextName : Int

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

mutual
  makeLam : {vars : _} -> {auto l : Ref Lifts LiftState} ->
            FC -> LiftOrigin -> (bound : Scope) -> NamedCExp -> Core (Lifted vars)
  makeLam fc origin bound (NmLam _ x sc) = makeLam fc origin (x :: bound) sc
  makeLam fc origin bound sc = do
      scl <- liftExp {vars = bound ++ vars} sc
      let unused = getUnused (contractUsedMany {remove = bound} (usedVars initUsed scl))
          scl' = dropUnused {outer = bound} unused scl
      n <- genName
      update Lifts $ \st => { lifted $= ((n, MkLFun (dropped vars unused) bound scl') ::),
                            infos $= ((n, MkLiftInfo (basename st) origin (length bound)) ::) } st
      pure $ LUnderApp fc n (length bound) (allVars vars unused)
    where
      allPrfs : (vs : Scope) -> SizeOf seen -> (unused : Vect (length vs) Bool) -> List (Var (seen <>> vs))
      allPrfs [] _ _ = []
      allPrfs (v :: vs) p (False :: uvs) = mkVarChiply p :: allPrfs vs (p :< _) uvs
      allPrfs (v :: vs) p (True :: uvs) = allPrfs vs (p :< _) uvs

      allVars : (vs : Scope) -> (unused : Vect (length vs) Bool) -> List (Lifted vs)
      allVars vs unused = map (\(MkVar p) => LLocal fc p) (allPrfs vs [<] unused)

  liftExp : {vars : _} -> {auto l : Ref Lifts LiftState} -> NamedCExp -> Core (Lifted vars)
  liftExp (NmLocal fc x) = case isVar x vars of
      Just (MkVar p) => pure (LLocal fc p)
      Nothing => throw $ InternalError "[rc2] lambda lifting: \{show x} is not in scope"
  liftExp (NmRef fc n) = pure $ LAppName fc Nothing n []
  liftExp (NmLam fc x sc) = makeLam fc FromLambda [x] sc
  liftExp (NmLet fc x val sc) = pure $ LLet fc x !(liftExp val) !(liftExp {vars = x :: vars} sc)
  liftExp (NmApp fc (NmRef _ n) args) = LAppName fc Nothing n <$> traverse liftExp args
  liftExp (NmApp fc f args) = unload fc Nothing !(liftExp f) !(traverse liftExp args)
  liftExp (NmCon fc n ci t args) = LCon fc n ci t <$> traverse liftExp args
  liftExp (NmOp fc op args) = LOp fc Nothing op <$> traverseVect args
    where
      traverseVect : Vect k NamedCExp -> Core (Vect k (Lifted vars))
      traverseVect [] = pure []
      traverseVect (a :: as) = pure $ !(liftExp a) :: !(traverseVect as)
  liftExp (NmExtPrim fc p args) = LExtPrim fc Nothing p <$> traverse liftExp args
  liftExp (NmForce fc _ tm) = liftExp (NmApp fc tm [NmErased fc])
  liftExp (NmDelay fc lr tm) = makeLam fc (FromDelay lr) [MN "act" 0] tm
  liftExp (NmConCase fc sc alts def)
      = pure $ LConCase fc !(liftExp sc) !(traverse liftConAlt alts) !(traverseOpt liftExp def)
    where
      liftConAlt : NamedConAlt -> Core (LiftedConAlt vars)
      liftConAlt (MkNConAlt n ci t args body) = MkLConAlt n ci t args <$> liftExp {vars = args ++ vars} body
  liftExp (NmConstCase fc sc alts def)
      = pure $ LConstCase fc !(liftExp sc) !(traverse liftConstAlt alts) !(traverseOpt liftExp def)
    where
      liftConstAlt : NamedConstAlt -> Core (LiftedConstAlt vars)
      liftConstAlt (MkNConstAlt c body) = MkLConstAlt c <$> liftExp body
  liftExp (NmPrimVal fc c) = pure $ LPrimVal fc c
  liftExp (NmErased fc) = pure $ LErased fc
  liftExp (NmCrash fc msg) = pure $ LCrash fc msg

LiftResult : Type
LiftResult = (List (Name, LiftedDef), List (Name, LiftInfo))

liftBody : Name -> (vars : Scope) -> NamedCExp -> Core (Lifted vars, LiftResult)
liftBody n vars tm = do
    l <- newRef Lifts (MkLiftState n [] [] 0)
    tml <- liftExp {vars} tm
    st <- get Lifts
    pure (tml, (lifted st, infos st))

liftDef : (Name, FC, NamedDef) -> Core LiftResult
liftDef (n, _, MkNmFun args body) = do
    (b, (ds, is)) <- liftBody n args body
    pure ((n, MkLFun args Scope.empty b) :: ds, is)
liftDef (n, _, MkNmCon t a nt) = pure ([(n, MkLCon t a nt)], [])
liftDef (n, _, MkNmForeign ccs fargs ret) = pure ([(n, MkLForeign ccs fargs ret)], [])
liftDef (n, _, MkNmError body) = do
    (b, (ds, is)) <- liftBody n Scope.empty body
    pure ((n, MkLError b) :: ds, is)

||| Every definition of `cdata`, lifted, in the order upstream's
||| `lambdaLifted` has them, and a `LiftInfo` for each lifted one. With
||| `withMain`, `__mainExpression` and its lifts come first (incremental
||| compilation has no main expression).
export
lambdaLiftProgram : (withMain : Bool) -> CompileData ->
                    Core (List (Name, LiftedDef), SortedMap Name LiftInfo)
lambdaLiftProgram withMain cdata = do
    perDef <- traverse liftDef (namedDefs cdata)
    let defs = foldr (\(ds, _), acc => ds ++ acc) [] perDef
        infos = foldr (\(_, is), acc => is ++ acc) [] perDef
    if not withMain
       then pure (defs, fromList infos)
       else do
         let mainName = MN "__mainExpression" 0
         (m, (mdefs, minfos)) <- liftBody mainName Scope.empty (forget (mainExpr cdata))
         pure ((mainName, MkLFun Scope.empty Scope.empty m) :: (mdefs ++ defs), fromList (minfos ++ infos))

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
