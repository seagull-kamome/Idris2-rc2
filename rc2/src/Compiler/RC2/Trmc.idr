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
import Compiler.RC2.RCExp
import Compiler.RC2.Util

import Core.CompileExpr
import Core.Core
import Core.FC
import Core.Context

import Data.List
import Data.Maybe
import Data.SortedMap
import Data.SortedSet

%default covering

-------------------------------------------------------------------------------
-- Finding recursive sites

||| A recursive site's result local, mapped to the recursive call's
||| arguments and the hole's field index.
Sites : Type
Sites = SortedMap Int (List RCLocal, Nat)

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

||| Every recursive site in `f`'s tails. `env` maps a let-bound local to
||| its let's position and the final expression of its value; `barrier`
||| is the position of the latest let that must not move before a
||| recursive call bound earlier.
findSites : Name -> SortedSet Name -> RCExp -> Sites
findSites f newtypes body = go empty 0 (-1) body
  where
    recCall : SortedMap Int (Int, RCExp) -> Int -> RCLocal -> Maybe (Int, List RCLocal)
    recCall env barrier (RCLoc v) = case lookup v env of
        Just (pos, RAppName _ Nothing g as') =>
            if g == f && pos >= barrier && countUsesR (RCLoc v) body == 1
               then Just (v, as')
               else Nothing
        _ => Nothing
    recCall _ _ _ = Nothing

    go : SortedMap Int (Int, RCExp) -> Int -> Int -> RCExp -> Sites
    go env pos barrier (RLet _ var _ value rest) =
        let barrier' = if reorderable value then barrier else pos
        in go (insert var (pos, finalOf value) env) (pos + 1) barrier' rest
    go env _ barrier (RCon _ n ci _ args Nothing) =
        if not (heapCon ci) || contains n newtypes then empty
        else case mapMaybe (\(k, a) => map (\(v, as') => (v, as', k)) (recCall env barrier a)) (zip [0 .. length args] args) of
                  [(v, as', k)] => singleton v (as', k)
                  _ => empty
    go env pos barrier (RCmpCase _ _ _ _ t e) = mergeLeft (go env pos barrier t) (go env pos barrier e)
    go env pos barrier (RConCase _ _ alts mDef) =
        foldr (\(MkRConAlt _ _ _ _ b), acc => mergeLeft (go env pos barrier b) acc) (maybe empty (go env pos barrier) mDef) alts
    go env pos barrier (RConstCase _ _ alts mDef) =
        foldr (\(MkRConstAlt _ b), acc => mergeLeft (go env pos barrier b) acc) (maybe empty (go env pos barrier) mDef) alts
    go _ _ _ _ = empty

-------------------------------------------------------------------------------
-- Rewriting

||| `Entry` rewrites `f` itself; `Acc res last` rewrites the body of
||| `f#`, whose `res` is the chain's first cell and `last` the cell whose
||| hole is open.
data Mode = Entry | Acc Int Int

||| `value` without its final expression (the recursive call), its
||| leading lets kept in front of `rest`.
withoutFinal : RCExp -> RCExp -> RCExp
withoutFinal (RLet fc var rep value body) rest = RLet fc var rep value (withoutFinal body rest)
withoutFinal _ rest = rest

rewriteBody : {auto v : Ref VarId Int} -> Name -> Name -> Nat -> Sites -> Mode -> RCExp -> Core RCExp
rewriteBody f f' k sites mode = go
  where
    fill : FC -> Int -> RCLocal -> RCExp -> Core RCExp
    fill fc last value rest = do
        u <- freshVarId
        pure $ RLet fc u RBoxed (RFill fc (RCLoc last) k value []) rest

    siteArgs : List RCLocal -> Maybe (List RCLocal)
    siteArgs args = case mapMaybe (\a => case a of
                                             RCLoc x => map fst (lookup x sites)
                                             _ => Nothing) args of
                         [as'] => Just as'
                         _ => Nothing

    finish : Int -> Int -> RCExp -> Core RCExp
    finish res last e = do
        r <- freshVarId
        RLet emptyFC r RBoxed e <$> fill emptyFC last (RCLoc r) (RV emptyFC (RCLoc res))

    other : RCExp -> Core RCExp
    other e = case mode of
        Entry => pure e
        Acc res last => case e of
            RAppName fc Nothing g as' =>
                if g == f then pure (RAppName fc Nothing f' (as' ++ [RCLoc res, RCLoc last]))
                          else finish res last e
            RCrash _ _ => pure e
            RV fc x => fill fc last x (RV fc (RCLoc res))
            _ => finish res last e

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
    go e@(RCon fc n ci tag args Nothing) = case siteArgs args of
        Nothing => other e
        Just as' => do
            c <- freshVarId
            let holed = map (\a => case a of
                                        RCLoc x => if isJust (lookup x sites) then RCNull else a
                                        _ => a) args
                cell = RCon fc n ci tag holed Nothing
            case mode of
                 Entry => pure $ RLet fc c RBoxed cell (RAppName fc Nothing f' (as' ++ [RCLoc c, RCLoc c]))
                 Acc res last =>
                     RLet fc c RBoxed cell <$> fill fc last (RCLoc c) (RAppName fc Nothing f' (as' ++ [RCLoc res, RCLoc c]))
    go e = other e

-------------------------------------------------------------------------------
-- Whole program

||| Every eligible function becomes an entry plus its accumulating twin
||| `MN "rc2_trmc_<f>"`; everything else is left as is.
export
applyTrmc : {auto v : Ref VarId Int} -> List (Name, RCDef) -> Core (List (Name, RCDef))
applyTrmc defs = do
    _ <- newRef FreshId 0
    -- Bound here, not in `where`: a `where` binding is re-evaluated at
    -- every use (doc/constant-constructor-specialization.md).
    newtypes <- pure $ the (SortedSet Name) $ fromList (mapMaybe (\(n, d) => case d of
                                                                       MkRCCon _ _ (Just _) => Just n
                                                                       _ => Nothing) defs)
    existing <- pure $ the (SortedSet Name) $ fromList (map fst defs)
    foldr (++) [] <$> traverse (one newtypes existing) defs
  where
    fresh : {auto r : Ref FreshId Int} -> SortedSet Name -> Name -> Core Name
    fresh existing n = do
        i <- freshId
        let cand = MN ("rc2_trmc_" ++ cName n) i
        if contains cand existing then fresh existing n else pure cand

    one : {auto r : Ref FreshId Int} -> SortedSet Name -> SortedSet Name -> (Name, RCDef) -> Core (List (Name, RCDef))
    one newtypes existing (n, d@(MkRCFun args@(_ :: _) RBoxed False body)) =
        let sites = findSites n newtypes body
        in case nub (map snd (values sites)) of
                [k] => do
                    n' <- fresh existing n
                    res <- freshVarId
                    last <- freshVarId
                    entry <- rewriteBody n n' k sites Entry body
                    acc <- rewriteBody n n' k sites (Acc res last) body
                    pure [ (n, MkRCFun args RBoxed False entry)
                         , (n', MkRCFun (args ++ [(res, RBoxed), (last, RBoxed)]) RBoxed False acc) ]
                _ => pure [(n, d)]
    one _ _ nd = pure [nd]
