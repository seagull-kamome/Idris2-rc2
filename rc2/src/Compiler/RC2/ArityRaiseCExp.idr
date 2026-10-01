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

mutual
  ||| Occurrences of the local `x` in `e` (not minding shadowing; a
  ||| rebinding of `x` makes `moveInto` give up anyway).
  uses : Name -> NamedCExp -> Nat
  uses x (NmLocal _ y) = if x == y then 1 else 0
  uses x (NmLam _ _ b) = uses x b
  uses x (NmLet _ _ v b) = uses x v + uses x b
  uses x (NmApp _ g args) = uses x g + usesAll x args
  uses x (NmCon _ _ _ _ args) = usesAll x args
  uses x (NmOp _ _ args) = usesAll x (toList args)
  uses x (NmExtPrim _ _ args) = usesAll x args
  uses x (NmForce _ _ t) = uses x t
  uses x (NmDelay _ _ t) = uses x t
  uses x (NmConCase _ sc alts def) =
      uses x sc + sum (map (\(MkNConAlt _ _ _ _ b) => uses x b) alts) + maybe 0 (uses x) def
  uses x (NmConstCase _ sc alts def) =
      uses x sc + sum (map (\(MkNConstAlt _ b) => uses x b) alts) + maybe 0 (uses x) def
  uses _ _ = 0

  usesAll : Name -> List NamedCExp -> Nat
  usesAll x = sum . map (uses x)

||| Every local `e` names.
localsIn : NamedCExp -> List Name
localsIn (NmLocal _ y) = [y]
localsIn (NmLam _ _ b) = localsIn b
localsIn (NmLet _ _ v b) = localsIn v ++ localsIn b
localsIn (NmApp _ g args) = localsIn g ++ concatMap localsIn args
localsIn (NmCon _ _ _ _ args) = concatMap localsIn args
localsIn (NmOp _ _ args) = concatMap localsIn (toList args)
localsIn (NmExtPrim _ _ args) = concatMap localsIn args
localsIn (NmForce _ _ t) = localsIn t
localsIn (NmDelay _ _ t) = localsIn t
localsIn (NmConCase _ sc alts def) =
    localsIn sc ++ concatMap (\(MkNConAlt _ _ _ _ b) => localsIn b) alts ++ maybe [] localsIn def
localsIn (NmConstCase _ sc alts def) =
    localsIn sc ++ concatMap (\(MkNConstAlt _ b) => localsIn b) alts ++ maybe [] localsIn def
localsIn _ = []

||| `e` with its one use of `x`, an application `x w rest`, replaced by
||| `mk w rest`; `Nothing` if that use is anything else, or if a binder
||| on the way to it rebinds a name in `bad` (`x` and the names the moved
||| expression reads), which would capture them.
moveInto : Name -> List Name -> (NamedCExp -> List NamedCExp -> NamedCExp) -> NamedCExp -> Maybe NamedCExp
moveInto x bad mk e = go e
  where
    has : NamedCExp -> Bool
    has t = uses x t > 0

    binds : Name -> Bool
    binds y = elem y bad

    -- The one argument holding the use, rewritten; the others as they are.
    goList : List NamedCExp -> Maybe (List NamedCExp)

    go : NamedCExp -> Maybe NamedCExp
    go (NmApp fc h@(NmLocal _ y) (w :: rest)) =
        if y == x && not (has w) && not (any has rest)
           then Just (mk w rest)
           else NmApp fc h <$> goList (w :: rest)
    go (NmLam fc y b) = if binds y then Nothing else NmLam fc y <$> go b
    go (NmLet fc y v b) =
        if has v then (\v' => NmLet fc y v' b) <$> go v
        else if binds y then Nothing else NmLet fc y v <$> go b
    go (NmApp fc g args) =
        if has g then (\g' => NmApp fc g' args) <$> go g else NmApp fc g <$> goList args
    go (NmCon fc n ci t args) = NmCon fc n ci t <$> goList args
    go (NmExtPrim fc p args) = NmExtPrim fc p <$> goList args
    go (NmForce fc lr t) = NmForce fc lr <$> go t
    go (NmDelay fc lr t) = NmDelay fc lr <$> go t
    go (NmConCase fc sc alts def) =
        if has sc then (\sc' => NmConCase fc sc' alts def) <$> go sc
        else case break (\(MkNConAlt _ _ _ _ b) => has b) alts of
                  (pre, MkNConAlt n ci t as b :: post) =>
                      if any binds as then Nothing
                      else (\b' => NmConCase fc sc (pre ++ MkNConAlt n ci t as b' :: post) def) <$> go b
                  (_, []) => (\d => NmConCase fc sc alts (Just d)) <$> (def >>= go)
    go (NmConstCase fc sc alts def) =
        if has sc then (\sc' => NmConstCase fc sc' alts def) <$> go sc
        else case break (\(MkNConstAlt _ b) => has b) alts of
                  (pre, MkNConstAlt c b :: post) =>
                      (\b' => NmConstCase fc sc (pre ++ MkNConstAlt c b' :: post) def) <$> go b
                  (_, []) => (\d => NmConstCase fc sc alts (Just d)) <$> (def >>= go)
    -- Anything else (an `NmOp`'s argument, say) is left alone.
    go _ = Nothing

    goList [] = Nothing
    goList (a :: as) = if has a then (:: as) <$> go a else (a ::) <$> goList as

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
      -- `let x = f xs in ... x w ...`, `x`'s only use: the closure is
      -- applied at once there too, so that use calls the raised version
      -- (a recursive call bound before the world's lambda, say). Building
      -- the closure computes nothing, so it can move to its use.
      go (NmLet fc x v b) =
          let v' = go v
              b' = go b
              kept = NmLet fc x v' b'
          in case v' of
                  NmApp ifc (NmRef rfc f) xs =>
                      if contains f r && lookup f arity == Just (length xs) && uses x b' == 1
                         then fromMaybe kept $
                                moveInto x (x :: concatMap localsIn xs)
                                  (\w', rest => let call = NmApp ifc (NmRef rfc (raisedName f)) (xs ++ [w'])
                                                in if null rest then call else NmApp ifc call rest)
                                  b'
                         else kept
                  _ => kept
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
