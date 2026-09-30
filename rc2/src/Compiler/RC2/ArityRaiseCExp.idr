||| World arity raising on the named case trees, before lambda lifting: a
||| function whose every tail is a lambda (the world's, for an `IO` or
||| `Core` function) gets a version taking that argument itself, the
||| lambdas' bodies in place, and a call applied at once calls it.
||| Design: `rc2/doc/world-arity-raising.md`. Disable with
||| `--directive noarityraise`.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Compiler.RC2.ArityRaiseCExp

import Compiler.RC2.Emit.Util

import Core.CompileExpr
import Core.Context
import Core.Core
import Core.FC
import Core.Name

import Data.List
import Data.Maybe
import Data.SortedMap
import Data.SortedSet
import Data.Vect

%default covering

-------------------------------------------------------------------------------
-- Plan

data Tail = TLam | TCrash | TCall Name Nat | TOther

tails : NamedCExp -> List Tail
tails (NmLam _ _ _) = [TLam]
tails (NmLet _ _ _ b) = tails b
tails (NmConCase _ _ alts def) =
    foldr (\(MkNConAlt _ _ _ _ b), acc => tails b ++ acc) (maybe [] tails def) alts
tails (NmConstCase _ _ alts def) =
    foldr (\(MkNConstAlt _ b), acc => tails b ++ acc) (maybe [] tails def) alts
tails (NmCrash _ _) = [TCrash]
tails (NmApp _ (NmRef _ g) args) = [TCall g (length args)]
tails _ = [TOther]

||| The functions to raise: every tail a lambda, a crash, or a
||| saturated tail call to another such function (a greatest fixpoint),
||| reaching at least one lambda. A CAF is left alone: its closure is
||| built once and shared.
raisePlan : List (Name, NamedDef) -> SortedSet Name
raisePlan defs =
    let arity : SortedMap Name Nat := fromList (mapMaybe arityOf defs)
        tbl : SortedMap Name (List Tail) := fromList (mapMaybe (tailsOf arity) defs)
        closed = shrink tbl (fromList (keys tbl))
    in reach tbl closed (fromList (filter (\n => any isLam (fromMaybe [] (lookup n tbl))) (Prelude.toList closed)))
  where
    arityOf : (Name, NamedDef) -> Maybe (Name, Nat)
    arityOf (n, MkNmFun args _) = Just (n, length args)
    arityOf _ = Nothing

    ok : SortedMap Name Nat -> Tail -> Bool
    ok _ TLam = True
    ok _ TCrash = True
    ok arity (TCall g k) = lookup g arity == Just k
    ok _ TOther = False

    tailsOf : SortedMap Name Nat -> (Name, NamedDef) -> Maybe (Name, List Tail)
    tailsOf arity (n, MkNmFun (_ :: _) b) = let ts = tails b in if all (ok arity) ts then Just (n, ts) else Nothing
    tailsOf _ _ = Nothing

    isLam : Tail -> Bool
    isLam TLam = True
    isLam _ = False

    callsIn : SortedSet Name -> Tail -> Bool
    callsIn s (TCall g _) = contains g s
    callsIn _ _ = False

    inSet : SortedSet Name -> Tail -> Bool
    inSet s (TCall g _) = contains g s
    inSet _ _ = True

    shrink : SortedMap Name (List Tail) -> SortedSet Name -> SortedSet Name
    shrink tbl s =
        let s' = fromList (filter (\n => all (inSet s) (fromMaybe [] (lookup n tbl))) (Prelude.toList s))
        in if length (Prelude.toList s') == length (Prelude.toList s) then s' else shrink tbl s'

    reach : SortedMap Name (List Tail) -> SortedSet Name -> SortedSet Name -> SortedSet Name
    reach tbl closed ps =
        let ps' = fromList (filter (\n => contains n ps || any (callsIn ps) (fromMaybe [] (lookup n tbl)))
                                   (Prelude.toList closed))
        in if length (Prelude.toList ps') == length (Prelude.toList ps) then ps' else reach tbl closed ps'

-------------------------------------------------------------------------------
-- Rewrite

raisedName : Name -> Name
raisedName n = MN ("rc2_raised_" ++ cName n) 0

||| `body`'s tails handed `w`: a lambda binds its parameter to it, a tail
||| call calls the raised version, a crash stays.
raiseTails : SortedSet Name -> FC -> Name -> NamedCExp -> NamedCExp
raiseTails r fc w (NmLam lfc x b) = NmLet lfc x (NmLocal fc w) b
raiseTails r fc w (NmLet lfc x v b) = NmLet lfc x v (raiseTails r fc w b)
raiseTails r fc w (NmConCase cfc sc alts def) =
    NmConCase cfc sc (map (\(MkNConAlt n ci t as b) => MkNConAlt n ci t as (raiseTails r fc w b)) alts)
              (map (raiseTails r fc w) def)
raiseTails r fc w (NmConstCase cfc sc alts def) =
    NmConstCase cfc sc (map (\(MkNConstAlt c b) => MkNConstAlt c (raiseTails r fc w b)) alts)
                (map (raiseTails r fc w) def)
raiseTails r fc w (NmApp afc (NmRef rfc g) args) =
    NmApp afc (NmRef rfc (raisedName g)) (args ++ [NmLocal fc w])
raiseTails _ _ _ e = e

||| Every `(f xs) w` with `f` raised and `xs` saturating it calls the
||| raised version instead.
rewriteSites : SortedSet Name -> SortedMap Name Nat -> NamedCExp -> NamedCExp
rewriteSites r arity = go
  where
    mutual
      go : NamedCExp -> NamedCExp
      go (NmApp fc (NmApp ifc (NmRef rfc f) xs) (w :: rest)) =
          let xs' = map go xs
              w' = go w
              rest' = map go rest
          in if contains f r && lookup f arity == Just (length xs)
                then let call = NmApp ifc (NmRef rfc (raisedName f)) (xs' ++ [w'])
                     in if null rest' then call else NmApp fc call rest'
                else NmApp fc (NmApp ifc (NmRef rfc f) xs') (w' :: rest')
      go (NmLam fc x b) = NmLam fc x (go b)
      go (NmLet fc x v b) = NmLet fc x (go v) (go b)
      go (NmApp fc g args) = NmApp fc (go g) (map go args)
      go (NmCon fc n ci t args) = NmCon fc n ci t (map go args)
      go (NmOp fc op args) = NmOp fc op (map go args)
      go (NmExtPrim fc p args) = NmExtPrim fc p (map go args)
      go (NmForce fc lr t) = NmForce fc lr (go t)
      go (NmDelay fc lr t) = NmDelay fc lr (go t)
      go (NmConCase fc sc alts def) =
          NmConCase fc (go sc) (map (\(MkNConAlt n ci t as b) => MkNConAlt n ci t as (go b)) alts) (map go def)
      go (NmConstCase fc sc alts def) =
          NmConstCase fc (go sc) (map (\(MkNConstAlt c b) => MkNConstAlt c (go b)) alts) (map go def)
      go e = e

||| Raises every planned function; the original becomes a lambda
||| handing its world to the raised version, for a caller that keeps
||| the closure.
export
applyArityRaiseCExp : Maybe NamedCExp -> List (Name, FC, NamedDef) -> Core (Maybe NamedCExp, List (Name, FC, NamedDef))
applyArityRaiseCExp main defs = do
    let named = map (\(n, _, d) => (n, d)) defs
        r = raisePlan named
        arity : SortedMap Name Nat :=
            fromList (mapMaybe (\(n, d) => case d of
                                               MkNmFun args _ => Just (n, length args)
                                               _ => Nothing) named)
        site = rewriteSites r arity
    pure ( map site main
         , foldr (\(n, fc, d), acc => raise r site n fc d ++ acc) [] defs )
  where
    w : Name
    w = MN "rc2world" 0

    raise : SortedSet Name -> (NamedCExp -> NamedCExp) -> Name -> FC -> NamedDef -> List (Name, FC, NamedDef)
    raise r site n fc (MkNmFun args b) =
        let b' = site b in
        if contains n r
           then [ (n, fc, MkNmFun args (NmLam fc w (NmApp fc (NmRef fc (raisedName n)) (map (NmLocal fc) args ++ [NmLocal fc w]))))
                , (raisedName n, fc, MkNmFun (args ++ [w]) (raiseTails r fc w b')) ]
           else [(n, fc, MkNmFun args b')]
    raise _ site n fc (MkNmError b) = [(n, fc, MkNmError (site b))]
    raise _ _ n fc d = [(n, fc, d)]
