||| A constructor that never leaves the function's frame is built in the
||| frame (`RStackCon`) and not on the heap. `v` qualifies when it is bound
||| by `let v = con ..` and read only by a `case` and by non-tail calls whose
||| parameter does not let it escape. The caller's `dup`/`drop`/`reuseOffer`
||| of `v` go (`drop [v]` becomes a `drop` of its boxed fields, as for a
||| struct scrutinee), and a call that consumed `v` is followed by that `drop`.
||| See `rc2/doc/stack-con.md`. Disable with `--directive nostackcon`.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Compiler.RC2.StackCon

import Compiler.RC2.RCExp
import Compiler.RC2.Types
import Compiler.RC2.Util

import Core.CompileExpr
import Core.Context
import Core.FC
import Core.TT

import Data.List
import Data.List1
import Data.Maybe
import Data.SortedMap
import Data.SortedSet

%default covering

||| A parameter of a function: its name and position.
ParamKey : Type
ParamKey = (Name, Nat)

||| The parameters `p` is passed to by `body`, or `Nothing` when `p` is read in
||| any other way than by a `case` (a `reuseOffer` of `p` included).
paramDeps : Int -> RCExp -> Maybe (List ParamKey)
paramDeps p = go
  where
    isP : RCLocal -> Bool
    isP = (== RCLoc p)

    positions : Name -> List RCLocal -> List ParamKey
    positions g args = mapMaybe (\(i, a) => if isP a then Just (g, i) else Nothing) (zip [0 .. length args] args)

    go : RCExp -> Maybe (List ParamKey)
    go (RDup _ _ _ k) = go k
    go (RDrop _ _ k) = go k
    go (RFree _ _ k) = go k
    go (RReleaseReuse _ _ k) = go k
    go (RReuseOffer _ sc ds us k) = if isP sc || any isP ds || any isP us then Nothing else go k
    go (RConCase _ _ alts mDef) =
        concat <$> traverse go (map (\(MkRConAlt _ _ _ _ b) => b) alts ++ maybe [] pure mDef)
    go (RAppName _ lazy g args) =
        if isJust lazy then (if any isP args then Nothing else Just []) else Just (positions g args)
    go (RAppNameRep _ g _ _ pd args) = if any isP pd then Nothing else Just (positions g args)
    go e = if any isP (directReads e) then Nothing else concat <$> traverse go (children e)

||| The parameters no callee lets escape (a greatest fixed point: a parameter
||| passed on is safe when the parameter it goes to is).
nonEscaping : List (Name, RCDef) -> SortedSet ParamKey
nonEscaping defs =
    let known : SortedSet ParamKey := fromList (map fst start)
        dependents : SortedMap ParamKey (List ParamKey) :=
            foldl (\m, (k, ds) => foldl (\m2, d => insert d (k :: fromMaybe [] (lookup d m2)) m2) m ds) (the (SortedMap ParamKey (List ParamKey)) empty) start
        unknown : List ParamKey := concatMap (\(_, ds) => filter (\d => not (contains d known)) ds) start
        escaping = spread dependents unknown (the (SortedSet ParamKey) empty)
    in fromList (filter (\k => not (contains k escaping)) (map fst start))
  where
    start : List (ParamKey, List ParamKey)
    start = concatMap entries defs
      where
        entries : (Name, RCDef) -> List (ParamKey, List ParamKey)
        entries (n, MkRCFun args _ _ body) =
            mapMaybe (\(i, (p, _)) => map (\ds => ((n, i), ds)) (paramDeps p body)) (zip [0 .. length args] args)
        entries _ = []

    spread : SortedMap ParamKey (List ParamKey) -> List ParamKey -> SortedSet ParamKey -> SortedSet ParamKey
    spread _ [] seen = seen
    spread dependents (b :: rest) seen =
        if contains b seen then spread dependents rest seen
        else spread dependents (fromMaybe [] (lookup b dependents) ++ rest) (insert b seen)

isBoxed : Rep -> Bool
isBoxed RBoxed = True
isBoxed _ = False

||| `v`'s ownership of a field: the local to `drop`, nothing for an immortal
||| constant, or `Nothing` when the local is not known to be Boxed or the constant
||| is boxed afresh when read (a native literal), which nothing would release.
fieldOwner : SortedMap Int Rep -> RCLocal -> Maybe (List RCLocal)
fieldOwner env l@(RCLoc i) = if maybe False isBoxed (lookup i env) then Just [l] else Nothing
fieldOwner _ (RCConst c) = if isJust (litRep c) then Nothing else Just []
fieldOwner _ _ = Just []

||| A `let` value that is a tagged constructor of one to `maxConstConFields` fields.
asCon : RCExp -> Maybe (FC, Name, ConInfo, Int, List RCLocal)
asCon (RCon fc n ci (Just tag) args Nothing) =
    if isNullCon ci || null args || length args > maxConstConFields then Nothing else Just (fc, n, ci, tag, args)
asCon _ = Nothing

||| `body` with the stack constructor `v` (owning `fs`) in place of the heap one,
||| or `Nothing` when `v` is used in a way a stack constructor cannot be.
rewriteUses : SortedSet ParamKey -> Int -> List RCLocal -> RCExp -> Maybe RCExp
rewriteUses ok v fs = go
  where
    isV : RCLocal -> Bool
    isV = (== RCLoc v)

    dropFields : RCExp -> RCExp
    dropFields k = if null fs then k else RDrop emptyFC fs k

    dropsOf : List RCLocal -> List RCLocal
    dropsOf vs = if any isV vs then filter (not . isV) vs ++ fs else vs

    argIndex : List RCLocal -> Maybe Nat
    argIndex args = case filter (\(_, a) => isV a) (zip [0 .. length args] args) of
                         [(i, _)] => Just i
                         _ => Nothing

    takesV : RCExp -> Bool
    takesV (RAppName _ _ _ args) = any isV args
    takesV (RAppNameRep _ _ _ _ pd args) = any isV (pd ++ args)
    takesV _ = False

    okCall : RCExp -> Maybe ()
    okCall (RAppName _ Nothing g args) = do
        i <- argIndex args
        guard (contains (g, i) ok)
    okCall (RAppNameRep _ g _ _ pd args) = do
        guard (not (any isV pd))
        i <- argIndex args
        guard (contains (g, i) ok)
    okCall _ = Nothing

    peelWrappers : RCExp -> Maybe (RCExp -> RCExp, RCExp)
    peelWrappers (RDup fc x n k) = if isV x then Nothing else map (\(w, c) => (RDup fc x n . w, c)) (peelWrappers k)
    peelWrappers (RDrop fc vs k) =
        let vs' = dropsOf vs
        in map (\(w, c) => ((\r => if null vs' then w r else RDrop fc vs' (w r)), c)) (peelWrappers k)
    peelWrappers e = Just (id, e)

    go : RCExp -> Maybe RCExp
    go (RDup fc x n k) = if isV x then Nothing else RDup fc x n <$> go k
    go (RDrop fc vs k) =
        let vs' = dropsOf vs
        in (\k' => if null vs' then k' else RDrop fc vs' k') <$> go k
    go (RFree fc x k) = if isV x then dropFields <$> go k else RFree fc x <$> go k
    go (RReleaseReuse fc x k) = if isV x then go k else RReleaseReuse fc x <$> go k
    go (RReuseOffer fc sc ds us k) =
        if isV sc then (\k' => foldr (\d, acc => RDup fc d 0 acc) (dropFields k') ds) <$> go k
        else if any isV ds || any isV us then Nothing
        else RReuseOffer fc sc ds us <$> go k
    go (RCon fc n ci tag args reuseFrom) =
        if any isV args then Nothing
        else Just (RCon fc n ci tag args (if reuseFrom == Just (RCLoc v) then Nothing else reuseFrom))
    go (RConCase fc sc alts mDef) = do
        alts' <- traverse (\(MkRConAlt n ci t as b) => MkRConAlt n ci t as <$> go b) alts
        mDef' <- traverse go mDef
        pure (RConCase fc sc alts' mDef')
    go (RLet fc y rep value body) = do
        (wrap, core) <- peelWrappers value
        if takesV core
           then do okCall core
                   body' <- go body
                   pure (RLet fc y rep (wrap core) (dropFields body'))
           else RLet fc y rep <$> go value <*> go body
    go e = if any isV (directReads e) then Nothing else traverseChildren go e

||| `let x = (let y = a; b) in c` as `let y = a in let x = b in c`, and `dup`/`drop`
||| in front of a value moved out in front of the `let`: what a value
||| that is a straight run of statements means.
flatten : RCExp -> RCExp
flatten (RLet fc x rep (RLet fc2 y r2 v2 inner) body) = flatten (RLet fc2 y r2 v2 (flatten (RLet fc x rep inner body)))
flatten (RLet fc x rep (RDup fc2 a n k) body) = RDup fc2 a n (flatten (RLet fc x rep k body))
flatten (RLet fc x rep (RDrop fc2 vs k) body) = RDrop fc2 vs (flatten (RLet fc x rep k body))
flatten e = e

||| A value that is a straight run of statements building a constructor: the
||| only values worth moving out in front of their `let`.
runHasCon : RCExp -> Bool
runHasCon (RLet _ _ _ v k) = isJust (asCon v) || runHasCon v || runHasCon k
runHasCon (RDup _ _ _ k) = runHasCon k
runHasCon (RDrop _ _ k) = runHasCon k
runHasCon e = isJust (asCon e)

mutual
  ||| Walks a body, replacing every qualifying `let v = con ..`. `noFlat` is set
  ||| inside a value already moved out in front of its `let`.
  stackWalk : SortedSet ParamKey -> SortedMap Int Rep -> Bool -> RCExp -> RCExp
  stackWalk ok env noFlat (RLet fc x rep value body) =
      let env' = insert x rep env
          tryFlat = not noFlat && runHasCon value
          value' = stackWalk ok env (noFlat || tryFlat) value
          body' = stackWalk ok env' False body
      in case the (RCExp, Bool) (if tryFlat then stackChain ok env x (flatten (RLet fc x rep value' body')) else (RLet fc x rep value' body', False)) of
              (flat, True) => flat
              _ => fst (letWith ok env' fc x rep value' body')
  stackWalk ok env noFlat (RLoop fc ps initial pd k) =
      RLoop fc ps initial pd (stackWalk ok (foldl (\m, (i, r) => insert i r m) env ps) noFlat k)
  stackWalk ok env noFlat (RConCase fc sc alts mDef) =
      let boxedScrut = case sc of
                            RCLoc s => maybe False isBoxed (lookup s env)
                            _ => False
          bind : SortedMap Int Rep -> List Int -> SortedMap Int Rep
          bind m as = if boxedScrut then foldl (\m', a => insert a RBoxed m') m as else m
      in RConCase fc sc (map (\(MkRConAlt n ci t as b) => MkRConAlt n ci t as (stackWalk ok (bind env as) noFlat b)) alts)
                  (map (stackWalk ok env noFlat) mDef)
  stackWalk ok env noFlat e = mapChildren (stackWalk ok env noFlat) e

  ||| The statements `flatten` put in front of the `let` of `x` (their values already
  ||| walked), each tried as a stack constructor; `True` when one became one.
  stackChain : SortedSet ParamKey -> SortedMap Int Rep -> Int -> RCExp -> (RCExp, Bool)
  stackChain ok env x (RDup fc a n k) = mapFst (RDup fc a n) (stackChain ok env x k)
  stackChain ok env x (RDrop fc vs k) = mapFst (RDrop fc vs) (stackChain ok env x k)
  stackChain ok env x (RLet fc y rep v inner) =
      let env' = insert y rep env
          (inner', c) = if y == x then (inner, False) else stackChain ok env' x inner
          (e, c2) = letWith ok env' fc y rep v inner'
      in (e, c || c2)
  stackChain _ _ _ e = (e, False)

  ||| `let y = v in inner`, as a stack constructor when `y` qualifies.
  letWith : SortedSet ParamKey -> SortedMap Int Rep -> FC -> Int -> Rep -> RCExp -> RCExp -> (RCExp, Bool)
  letWith ok env fc v rep value body =
      case tryStack of
           Just e => (e, True)
           Nothing => (RLet fc v rep value body, False)
    where
      tryStack : Maybe RCExp
      tryStack = do
          guard (isBoxed rep)
          (fc', n, ci, tag, args) <- asCon value
          owned <- traverse (fieldOwner env) args
          body' <- rewriteUses ok v (concat owned) body
          pure (RLet fc v RBoxed (RStackCon fc' n ci tag args) body')

||| The most nodes a function may have to be searched: each constructor looks
||| through the rest of its function, so the work grows with the square of the size.
maxBodySize : Nat
maxBodySize = 4000

||| Whether `e` has at most `n` nodes.
sizeAtMost : Nat -> RCExp -> Bool
sizeAtMost n e = go [e] n
  where
    go : List RCExp -> Nat -> Bool
    go [] _ = True
    go _ Z = False
    go (x :: xs) (S k) = go (children x ++ xs) k

||| Puts the qualifying constructors of every function on the stack.
export
applyStackCon : List (Name, RCDef) -> List (Name, RCDef)
applyStackCon defs =
    let ok = nonEscaping defs
    in map (\(n, d) => (n, convert ok d)) defs
  where
    convert : SortedSet ParamKey -> RCDef -> RCDef
    convert ok (MkRCFun args r w body) =
        if sizeAtMost maxBodySize body
           then MkRCFun args r w (stackWalk ok (fromList args) False body)
           else MkRCFun args r w body
    convert _ d = d
