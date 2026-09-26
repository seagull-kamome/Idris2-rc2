||| Tail recursion modulo constructor: a function whose recursive call
||| sits under a constructor (`x :: f xs`) gets an accumulating twin that
||| builds the cell first, fills the previous cell's hole with it, and
||| tail-calls itself, so Loop conversion turns the recursion into a
||| loop. Design, eligibility and pipeline position: `rc2/doc/trmc.md`.
||| Disable with `--directive notrmc`.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Compiler.RC2.Trmc

import Compiler.RC2.Emit.Util
import Compiler.RC2.MutualLoop
import Compiler.RC2.RCExp
import Compiler.RC2.Util

import Core.CompileExpr
import Core.Core
import Core.FC
import Core.Context
import Core.Context.Log

import Data.List
import Data.Maybe
import Data.SortedMap
import Data.SortedSet

%default covering

-------------------------------------------------------------------------------
-- Finding recursive sites

||| A site's result local, mapped to the callee, the call's arguments and
||| the hole's field index.
Sites : Type
Sites = SortedMap Int (Name, List RCLocal, Nat)

finalOf : RCExp -> RCExp
finalOf (RLet _ _ _ _ body) = finalOf body
finalOf e = e

||| Whether evaluating `e` before instead of after a recursive call is
||| unobservable: no call, no closure application, no primitive with an
||| effect.
reorderable : RCExp -> Bool
reorderable (RLet _ _ _ value body) = reorderable value && reorderable body
reorderable (RV _ _) = True
reorderable (RCon _ _ _ _ _ _) = True
reorderable (ROp _ Nothing _ _ _) = True
reorderable (RPrimVal _ _) = True
reorderable (RErased _) = True
reorderable (RUnderApp _ _ _ _) = True
reorderable _ = False

||| Constructors whose cells are real heap objects with an `args` array.
heapCon : ConInfo -> Bool
heapCon DATACON = True
heapCon CONS = True
heapCon JUST = True
heapCon RECORD = True
heapCon _ = False

||| Every hole candidate in `f`'s tails, whatever it calls: the
||| last-evaluated strict call to a function of `arity` bound to a field
||| of a tail heap constructor, used only there, with nothing
||| unreorderable after it. `env` maps a let-bound local to its let's
||| position and the final expression of its value; `barrier` is the
||| position of the latest let that must not move before a call bound
||| earlier. The other calls of a site with several stay ordinary calls.
findSites : SortedMap Name Nat -> SortedSet Name -> RCExp -> Sites
findSites arity newtypes body = go empty 0 (-1) body
  where
    candidate : SortedMap Int (Int, RCExp) -> Int -> RCLocal -> Maybe (Int, Int, Name, List RCLocal)
    candidate env barrier (RCLoc v) = case lookup v env of
        Just (pos, RAppName _ Nothing g as') =>
            if lookup g arity == Just (length as') && pos >= barrier && countUsesR (RCLoc v) body == 1
               then Just (v, pos, g, as')
               else Nothing
        _ => Nothing
    candidate _ _ _ = Nothing

    latest : List (Int, Int, Name, List RCLocal, Nat) -> Maybe (Int, Name, List RCLocal, Nat)
    latest [] = Nothing
    latest (c :: cs) =
        let (v, _, g, as', k) = foldl (\a@(_, pa, _, _, _), b@(_, pb, _, _, _) => if pb > pa then b else a) c cs
        in Just (v, g, as', k)

    go : SortedMap Int (Int, RCExp) -> Int -> Int -> RCExp -> Sites
    go env pos barrier (RLet _ var _ value rest) =
        let barrier' = if reorderable value then barrier else pos
        in go (insert var (pos, finalOf value) env) (pos + 1) barrier' rest
    go env _ barrier (RCon _ n ci _ args Nothing) =
        if not (heapCon ci) || contains n newtypes then empty
        else case latest (mapMaybe (\(k, a) => map (\(v, p, g, as') => (v, p, g, as', k)) (candidate env barrier a)) (zip [0 .. length args] args)) of
                  Just (v, g, as', k) => singleton v (g, as', k)
                  Nothing => empty
    go env pos barrier (RCmpCase _ _ _ _ t e) = mergeLeft (go env pos barrier t) (go env pos barrier e)
    go env pos barrier (RConCase _ _ alts mDef) =
        foldr (\(MkRConAlt _ _ _ _ b), acc => mergeLeft (go env pos barrier b) acc) (maybe empty (go env pos barrier) mDef) alts
    go env pos barrier (RConstCase _ _ alts mDef) =
        foldr (\(MkRConstAlt _ b), acc => mergeLeft (go env pos barrier b) acc) (maybe empty (go env pos barrier) mDef) alts
    go _ _ _ _ = empty

||| The functions `e` tail-calls with their full arity.
tailCalls : SortedMap Name Nat -> RCExp -> List Name
tailCalls arity (RLet _ _ _ _ rest) = tailCalls arity rest
tailCalls arity (RAppName _ Nothing g as') = if lookup g arity == Just (length as') then [g] else []
tailCalls arity (RCmpCase _ _ _ _ t e) = tailCalls arity t ++ tailCalls arity e
tailCalls arity (RConCase _ _ alts mDef) =
    foldr (\(MkRConAlt _ _ _ _ b), acc => tailCalls arity b ++ acc) (maybe [] (tailCalls arity) mDef) alts
tailCalls arity (RConstCase _ _ alts mDef) =
    foldr (\(MkRConstAlt _ b), acc => tailCalls arity b ++ acc) (maybe [] (tailCalls arity) mDef) alts
tailCalls _ _ = []

-------------------------------------------------------------------------------
-- Rewriting

||| `Entry` rewrites a member itself; `Acc res last hk` rewrites the body
||| of its accumulating twin, whose `res` is the chain's first cell and
||| `last` the cell whose hole is open. `hk` holds that hole's field
||| index when the group's sites use more than one.
data Mode = Entry | Acc Int Int (Maybe Int)

||| `value` without its final expression (the call), its leading lets
||| kept in front of `rest`.
withoutFinal : RCExp -> RCExp -> RCExp
withoutFinal (RLet fc var rep value body) rest = RLet fc var rep value (withoutFinal body rest)
withoutFinal _ rest = rest

||| `acc` maps every group member to its accumulating twin; `sites` are
||| this member's sites into the group. `ks` are the group's distinct
||| hole indexes; with more than one, every twin takes the current one
||| as an extra argument.
rewriteBody : {auto v : Ref VarId Int} -> SortedMap Name Name -> List Nat -> Sites -> Mode -> RCExp -> Core RCExp
rewriteBody acc ks sites mode = go
  where
    fillAt : FC -> Int -> RCLocal -> RCExp -> Nat -> Core RCExp
    fillAt fc last value rest k = do
        u <- freshVarId
        pure $ RLet fc u RBoxed (RFill fc (RCLoc last) k value []) rest

    -- `rest` is let-free (a result or a tail call), so each branch can
    -- carry its own copy.
    fill : FC -> Int -> Maybe Int -> RCLocal -> RCExp -> Core RCExp
    fill fc last Nothing value rest = fillAt fc last value rest (fromMaybe 0 (head' ks))
    fill fc last (Just hk) value rest = do
        branches <- traverse (\k => (k,) <$> fillAt fc last value rest k) ks
        case reverse branches of
             ((_, dflt) :: others) =>
                 pure $ RConstCase fc (RCLoc hk) (map (\(k, b) => MkRConstAlt (I (cast k)) b) (reverse others)) (Just dflt)
             [] => pure rest

    holeArg : Nat -> List RCLocal
    holeArg k = if length ks > 1 then [RCConst (I (cast k))] else []

    siteOf : List RCLocal -> Maybe (Name, List RCLocal, Nat)
    siteOf args = case mapMaybe (\a => case a of
                                           RCLoc x => lookup x sites
                                           _ => Nothing) args of
                       [site] => Just site
                       _ => Nothing

    finish : Int -> Int -> Maybe Int -> RCExp -> Core RCExp
    finish res last hk e = do
        r <- freshVarId
        RLet emptyFC r RBoxed e <$> fill emptyFC last hk (RCLoc r) (RV emptyFC (RCLoc res))

    other : RCExp -> Core RCExp
    other e = case mode of
        Entry => pure e
        Acc res last hk => case e of
            RAppName fc Nothing g as' => case lookup g acc of
                Just g' => pure (RAppName fc Nothing g' (as' ++ [RCLoc res, RCLoc last] ++ map RCLoc (toList hk)))
                Nothing => finish res last hk e
            RCrash _ _ => pure e
            RV fc x => fill fc last hk x (RV fc (RCLoc res))
            _ => finish res last hk e

    go : RCExp -> Core RCExp
    go (RLet fc var rep value rest) =
        if isJust (lookup var sites)
           then withoutFinal value <$> go rest
           else RLet fc var rep value <$> go rest
    go (RCmpCase fc op args pd t e) = RCmpCase fc op args pd <$> go t <*> go e
    go (RConCase fc sc alts mDef) =
        RConCase fc sc <$> traverse (\(MkRConAlt n ci tag as b) => MkRConAlt n ci tag as <$> go b) alts
                       <*> traverseOpt go mDef
    go (RConstCase fc sc alts mDef) =
        RConstCase fc sc <$> traverse (\(MkRConstAlt c b) => MkRConstAlt c <$> go b) alts
                         <*> traverseOpt go mDef
    go e@(RCon fc n ci tag args Nothing) = case siteOf args of
        Nothing => other e
        Just (g, as', k) => do
            let g' = fromMaybe g (lookup g acc)
            c <- freshVarId
            let holed = map (\a => case a of
                                        RCLoc x => if isJust (lookup x sites) then RCNull else a
                                        _ => a) args
                cell = RCon fc n ci tag holed Nothing
            case mode of
                 Entry => pure $ RLet fc c RBoxed cell (RAppName fc Nothing g' (as' ++ [RCLoc c, RCLoc c] ++ holeArg k))
                 Acc res last hk =>
                     RLet fc c RBoxed cell <$> fill fc last hk (RCLoc c) (RAppName fc Nothing g' (as' ++ [RCLoc res, RCLoc c] ++ holeArg k))
    go e = other e

-------------------------------------------------------------------------------
-- Whole program

||| Functions linked by tail calls and holes into a strongly connected
||| group with at least one site each get an accumulating twin
||| `MN "rc2_trmc_<f>"`; the twins tail-call each other, which Loop (one
||| member) or MutualLoop (several) turns into a loop. Everything else
||| is left as is. See `rc2/doc/trmc.md`, "Phase 2 design".
export
applyTrmc : {auto c : Ref Ctxt Defs} -> {auto v : Ref VarId Int} -> List (Name, RCDef) -> Core (List (Name, RCDef))
applyTrmc defs = do
    _ <- newRef FreshId 0
    -- Bound here, not in `where`: a `where` binding is re-evaluated at
    -- every use (doc/constant-constructor-specialization.md).
    newtypes <- pure $ the (SortedSet Name) $ fromList (mapMaybe (\(n, d) => case d of
                                                                       MkRCCon _ _ (Just _) => Just n
                                                                       _ => Nothing) defs)
    existing <- pure $ the (SortedSet Name) $ fromList (map fst defs)
    arity <- pure $ the (SortedMap Name Nat) $ fromList (mapMaybe (\(n, d) => case d of
                                                                     MkRCFun args@(_ :: _) RBoxed False _ => Just (n, length args)
                                                                     _ => Nothing) defs)
    allSites <- logTime 3 "rc2: TRMC (sites)" $ pure $ the (SortedMap Name Sites) $ fromList (mapMaybe (\(n, d) => case d of
                                                                           MkRCFun _ _ _ body => if isJust (lookup n arity)
                                                                                                    then Just (n, findSites arity newtypes body)
                                                                                                    else Nothing
                                                                           _ => Nothing) defs)
    -- Only edges to other functions: a one-member group needs no SCC
    -- (doc/trmc.md, "Phase 2 results").
    graph <- logTime 3 "rc2: TRMC (graph)" $ pure $ the Graph $ fromList (mapMaybe (\(n, d) => case d of
                                                       MkRCFun _ _ _ body => do
                                                           ss <- lookup n allSites
                                                           let out = filter (/= n) (map fst (values ss) ++ tailCalls arity body)
                                                           if null out then Nothing else Just (n, fromList out)
                                                       _ => Nothing) defs)
    multi <- logTime 3 "rc2: TRMC (SCC)" $ pure $ filter (\g => length g >= 2) (tarjanSCCs graph)
    inMulti <- pure $ the (SortedSet Name) $ fromList (foldr (++) [] multi)
    groups <- logTime 3 "rc2: TRMC (groups)" $ pure $ mapMaybe (group allSites) (multi ++ map (\n => [n]) (filter (\n => not (contains n inMulti)) (keys allSites)))
    twins <- the (Core (List (SortedMap Name Name, List Nat, SortedMap Name Sites))) $
                 traverse (\(members, ks, sites) => do
                              acc <- fromList <$> traverse (\m => (m,) <$> fresh existing m) members
                              pure (acc, ks, sites)) groups
    byMember <- pure $ the (SortedMap Name (SortedMap Name Name, List Nat, Sites)) $
                    fromList (foldr (++) [] (map (\(acc, ks, sites) => map (\(m, ss) => (m, (acc, ks, ss))) (SortedMap.toList sites)) twins))
    logTime 3 "rc2: TRMC (rewrite)" $ foldr (++) [] <$> traverse (one byMember) defs
  where
    fresh : {auto r : Ref FreshId Int} -> SortedSet Name -> Name -> Core Name
    fresh existing n = do
        i <- freshId
        let cand = MN ("rc2_trmc_" ++ cName n) i
        if contains cand existing then fresh existing n else pure cand

    ||| A component's members, its sites into itself and their distinct
    ||| hole indexes, if it has any site.
    group : SortedMap Name Sites -> List Name -> Maybe (List Name, List Nat, SortedMap Name Sites)
    group allSites members =
        let intoGroup : Sites -> Sites
            intoGroup ss = SortedMap.fromList (filter (\(_, (g, _, _)) => elem g members) (SortedMap.toList ss))
            own : List (Name, Sites)
            own = map (\m => (m, intoGroup (fromMaybe SortedMap.empty (lookup m allSites)))) members
            ks : List Nat
            ks = nub (foldr (++) [] (map (\(_, ss) => map (\(_, _, k) => k) (values ss)) own))
        in if null ks then Nothing else Just (members, ks, SortedMap.fromList own)

    one : SortedMap Name (SortedMap Name Name, List Nat, Sites) -> (Name, RCDef) -> Core (List (Name, RCDef))
    one byMember (n, d@(MkRCFun args ret w body)) = case lookup n byMember of
        Nothing => pure [(n, d)]
        Just (acc, ks, sites) => do
            let n' = fromMaybe n (lookup n acc)
            res <- freshVarId
            last <- freshVarId
            hk <- if length ks > 1 then Just <$> freshVarId else pure Nothing
            entry <- rewriteBody acc ks sites Entry body
            accBody <- rewriteBody acc ks sites (Acc res last hk) body
            pure [ (n, MkRCFun args ret w entry)
                 , (n', MkRCFun (args ++ [(res, RBoxed), (last, RBoxed)] ++ map (, RBoxed) (toList hk)) RBoxed False accBody) ]
    one _ nd = pure [nd]
