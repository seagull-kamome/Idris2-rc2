module Compiler.RC2.CmpMerge

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Merges two nested comparisons of the same operands into one:
--
--   cmp <T [x, y] then A else (cmp ==T [x, y] then A' else B)
--     ==>  cmp <=T [x, y] then A else B          (A' equal to A)
--
-- likewise {>, ==} -> >=, with the pair in either nesting order and
-- either operand order. This is what `compare x y /= GT` becomes once
-- the callee-first inliner has expanded `compare`. A comparison whose
-- two branches are equal is dropped as well (`compare x y /= LT` leaves
-- `cmp ==T [x, y] then T else T` behind). Runs before the dup/drop
-- annotation, so no `postDrop` or reference-count node exists yet. No
-- negation or branch swap is done: `cmp < then A else B` is not
-- `cmp >= then B else A` for a Double NaN. See rc2/doc/native-type-inference.md,
-- "Merging nested comparisons". Disable with `--directive nocmpmerge`.

import Compiler.RC2.RCExp
import Compiler.RC2.Types

import Core.CompileExpr
import Core.FC
import Core.TT

import Data.DPair
import Data.List
import Data.List1
import Data.Vect

%default covering

------------------------------------------------------------------------
-- Equality of two expressions up to the names of their own binders

||| Pairs (variable on the left, variable on the right) bound so far.
Env : Type
Env = List (Int, Int)

||| `Db` compared by its printed form, so `0.0` and `-0.0` stay different
||| (`Eq Constant` uses IEEE `==`).
eqConst : Constant -> Constant -> Bool
eqConst (Db a) (Db b) = show a == show b
eqConst a b = a == b

eqRep : Rep -> Rep -> Bool
eqRep RBoxed RBoxed = True
eqRep (RNative a) (RNative b) = a == b
eqRep (RInlineNative a) (RInlineNative b) = a == b
eqRep _ _ = False

eqLocals : Env -> List RCLocal -> List RCLocal -> Bool
eqLocal : Env -> RCLocal -> RCLocal -> Bool
eqLocal env (RCLoc i) (RCLoc j) =
    case lookup i env of
         Just j' => j' == j
         Nothing => not (any ((== j) . snd) env) && i == j
eqLocal _ (RCLoc _) _ = False
eqLocal _ RCNull RCNull = True
eqLocal _ (RCConst a) (RCConst b) = eqConst a b
eqLocal _ (RCEmptyCon n1 _ t1) (RCEmptyCon n2 _ t2) = n1 == n2 && t1 == t2
eqLocal env (RCConstCon n1 _ t1 a1) (RCConstCon n2 _ t2 a2) =
    n1 == n2 && t1 == t2 && eqLocals env a1 a2
eqLocal _ (RCConstClosure n1 m1) (RCConstClosure n2 m2) = n1 == n2 && m1 == m2
eqLocal _ _ _ = False

eqLocals _ [] [] = True
eqLocals env (a :: as) (b :: bs) = eqLocal env a b && eqLocals env as bs
eqLocals _ _ _ = False

eqMaybeLocal : Env -> Maybe RCLocal -> Maybe RCLocal -> Bool
eqMaybeLocal _ Nothing Nothing = True
eqMaybeLocal env (Just a) (Just b) = eqLocal env a b
eqMaybeLocal _ _ _ = False

||| Two expressions that compute the same thing, ignoring source
||| locations and the names of locals bound inside them. A constructor it
||| does not handle is never equal: the result `False` only loses a merge.
||| Free locals must be the same variable; bound ones may differ.
eqExp : Env -> RCExp -> RCExp -> Bool
eqAlts : Env -> List RConAlt -> List RConAlt -> Bool
eqConstAlts : Env -> List RConstAlt -> List RConstAlt -> Bool
eqDefault : Env -> Maybe RCExp -> Maybe RCExp -> Bool

eqExp env (RV _ a) (RV _ b) = eqLocal env a b
eqExp env (RAppName _ l1 n1 a1) (RAppName _ l2 n2 a2) = l1 == l2 && n1 == n2 && eqLocals env a1 a2
eqExp env (RUnderApp _ n1 m1 a1) (RUnderApp _ n2 m2 a2) = n1 == n2 && m1 == m2 && eqLocals env a1 a2
eqExp env (RApp _ l1 f1 a1) (RApp _ l2 f2 a2) = l1 == l2 && eqLocal env f1 f2 && eqLocals env (forget a1) (forget a2)
eqExp env (RLet _ v1 r1 val1 b1) (RLet _ v2 r2 val2 b2) =
    eqRep r1 r2 && eqExp env val1 val2 && eqExp ((v1, v2) :: env) b1 b2
eqExp env (RCon _ n1 ci1 t1 a1 r1) (RCon _ n2 ci2 t2 a2 r2) =
    n1 == n2 && ci1 == ci2 && t1 == t2 && eqLocals env a1 a2 && eqMaybeLocal env r1 r2
eqExp env (ROp _ l1 f1 a1 p1) (ROp _ l2 f2 a2 p2) =
    l1 == l2 && show f1 == show f2 && eqLocals env (toList a1) (toList a2) && eqLocals env p1 p2
eqExp env (RCmpCase _ op1 a1 p1 t1 f1) (RCmpCase _ op2 a2 p2 t2 f2) =
    show op1.fst == show op2.fst && eqLocals env (toList a1) (toList a2) && eqLocals env p1 p2
      && eqExp env t1 t2 && eqExp env f1 f2
eqExp env (RConCase _ s1 alts1 d1) (RConCase _ s2 alts2 d2) =
    eqLocal env s1 s2 && eqAlts env alts1 alts2 && eqDefault env d1 d2
eqExp env (RConstCase _ s1 alts1 d1) (RConstCase _ s2 alts2 d2) =
    eqLocal env s1 s2 && eqConstAlts env alts1 alts2 && eqDefault env d1 d2
eqExp _ (RPrimVal _ a) (RPrimVal _ b) = eqConst a b
eqExp _ (RErased _) (RErased _) = True
eqExp _ (RCrash _ a) (RCrash _ b) = a == b
eqExp _ _ _ = False

eqAlts _ [] [] = True
eqAlts env (MkRConAlt n1 ci1 t1 as1 b1 :: r1) (MkRConAlt n2 ci2 t2 as2 b2 :: r2) =
    n1 == n2 && ci1 == ci2 && t1 == t2 && length as1 == length as2
      && eqExp (zip as1 as2 ++ env) b1 b2 && eqAlts env r1 r2
eqAlts _ _ _ = False

eqConstAlts _ [] [] = True
eqConstAlts env (MkRConstAlt c1 b1 :: r1) (MkRConstAlt c2 b2 :: r2) =
    eqConst c1 c2 && eqExp env b1 b2 && eqConstAlts env r1 r2
eqConstAlts _ _ _ = False

eqDefault _ Nothing Nothing = True
eqDefault env (Just a) (Just b) = eqExp env a b
eqDefault _ _ _ = False

------------------------------------------------------------------------
-- The rewrite

||| A comparison seen as `<` or `==` of its operands, for any of the
||| five forms but `<=`/`>=`: `a > b` is `b < a`.
data Shape = Less | Same

||| `Just (shape, x, y)` for `<`, `>`, `==`; for `>` the operands are
||| swapped so that `Less` always reads `x < y`.
shapeOf : CmpOp -> Vect 2 RCLocal -> Maybe (Shape, RCLocal, RCLocal)
shapeOf (Element (LT _) _) [x, y] = Just (Less, x, y)
shapeOf (Element (GT _) _) [x, y] = Just (Less, y, x)
shapeOf (Element (EQ _) _) [x, y] = Just (Same, x, y)
shapeOf _ _ = Nothing

||| The merged comparison of a strict one (`<` or `>`, `strictOp`) with
||| `==`: `<=` or `>=` on the strict one's own operands.
mergedOp : CmpOp -> Maybe CmpOp
mergedOp (Element (LT ty) _) = Just (Element (LTE ty) IsLTE)
mergedOp (Element (GT ty) _) = Just (Element (GTE ty) IsGTE)
mergedOp _ = Nothing

||| `outer` and `inner` compare the same two operands in the same type, one
||| strictly and one for equality (`==` is symmetric, so its operands may
||| be swapped).
isPair : CmpOp -> Vect 2 RCLocal -> CmpOp -> Vect 2 RCLocal -> Bool
isPair op1 as1 op2 as2 =
    if cmpOpTy op1 == cmpOpTy op2 && (nativeEligible (cmpOpTy op1) || boxedCmpEligible (cmpOpTy op1))
       then pairedShapes (shapeOf op1 as1) (shapeOf op2 as2)
       else False
  where
    sameOperands : RCLocal -> RCLocal -> RCLocal -> RCLocal -> Bool
    sameOperands x1 y1 x2 y2 = (x1 == x2 && y1 == y2) || (x1 == y2 && y1 == x2)

    pairedShapes : Maybe (Shape, RCLocal, RCLocal) -> Maybe (Shape, RCLocal, RCLocal) -> Bool
    pairedShapes (Just (Less, x1, y1)) (Just (Same, x2, y2)) = sameOperands x1 y1 x2 y2
    pairedShapes (Just (Same, x1, y1)) (Just (Less, x2, y2)) = sameOperands x1 y1 x2 y2
    pairedShapes _ _ = False

||| One node, its children already rewritten.
mergeNode : RCExp -> RCExp
mergeNode e@(RCmpCase fc op args [] t f) =
    if eqExp [] t f then t
    else case (t, f) of
              (_, RCmpCase _ op2 args2 [] t2 f2) =>
                  if isPair op args op2 args2 && eqExp [] t t2
                     then mergeAs fc op args op2 args2 t f2
                     else e
              _ => e
  where
    -- The strict one of the pair gives the merged operator and operands.
    mergeAs : FC -> CmpOp -> Vect 2 RCLocal -> CmpOp -> Vect 2 RCLocal -> RCExp -> RCExp -> RCExp
    mergeAs fc op1 as1 op2 as2 keep rest =
        case (mergedOp op1, mergedOp op2) of
             (Just m, _) => mergeNode (RCmpCase fc m as1 [] keep rest)
             (_, Just m) => mergeNode (RCmpCase fc m as2 [] keep rest)
             _ => RCmpCase fc op1 as1 [] keep (RCmpCase fc op2 as2 [] keep rest)
mergeNode e = e

||| `mergeNode` on every node of `e`, children first.
export
mergeCmp : RCExp -> RCExp
mergeCmp e = mergeNode (mapChildren mergeCmp e)

||| `mergeCmp` over a definition's body.
export
mergeCmpDef : RCDef -> RCDef
mergeCmpDef (MkRCFun args retRep isWorker body) = MkRCFun args retRep isWorker (mergeCmp body)
mergeCmpDef (MkRCError body) = MkRCError (mergeCmp body)
mergeCmpDef d = d
