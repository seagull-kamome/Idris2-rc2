||| Which boxed functions can return a closure whose call is still pending
||| (a tail call made as a closure for the nearest trampoline to run), and so
||| which call sites need `idris2rc2_trampoline` at all.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Compiler.RC2.Pending

import Compiler.RC2.Emit.Util
import Compiler.RC2.RCExp

import Core.Context

import Data.List
import Data.SortedMap
import Data.SortedSet
import Data.String

%default covering

||| What one tail of a function body returns.
data TailKind = Done | Pending | Passes Name

||| The tails of `e`, through the RC wrappers, branches and loops. Only the forms
||| known to produce a finished value are `Done`; any other is `Pending`.
tailKinds : RCExp -> List TailKind
tailKinds (RLoop _ _ _ _ k) = tailKinds k
tailKinds (RLoopContinue _ _ _) = []
tailKinds (RAppNameRep _ n _ RBoxed _ _) = [Passes n]
tailKinds (RV _ _) = [Done]
tailKinds (RCon {}) = [Done]
tailKinds (RRetPack {}) = [Done]
tailKinds (RStackCon {}) = [Done]
tailKinds (RPrimVal {}) = [Done]
tailKinds (RErased _) = [Done]
tailKinds (RCrash {}) = [Done]
tailKinds (RUnderApp {}) = [Done]
tailKinds (RAppFFIInline {}) = [Done]
tailKinds (RDelay {}) = [Done]
tailKinds (RForce {}) = [Done]
tailKinds (ROp _ Nothing _ _ _) = [Done]
tailKinds (RExtPrim _ Nothing _ _ _) = [Done]
tailKinds e = maybe [Pending] (concatMap tailKinds) (tailChildren e)

||| The boxed functions of `defs` with the kinds of their tails.
funTails : List (Name, RCDef) -> SortedMap Name (List TailKind)
funTails defs = SortedMap.fromList (mapMaybe (\(n, d) => case d of
                                                           MkRCFun _ RBoxed _ body => Just (n, tailKinds body)
                                                           _ => Nothing) defs)

||| The functions that may return a pending closure: the least set holding
||| every function with a `Pending` tail, and every function that passes on
||| the result of a call to a member or to a function not defined here.
export
pendingFuns : List (Name, RCDef) -> SortedSet Name
pendingFuns defs = go (SortedSet.fromList seeds) seeds
  where
    funs : SortedMap Name (List TailKind)
    funs = funTails defs

    -- defined here, but not a boxed function: a constructor or a foreign wrapper
    others : SortedSet Name
    others = SortedSet.fromList (mapMaybe (\(n, d) => case d of
                                                         MkRCFun {} => Nothing
                                                         _ => Just n) defs)

    known : SortedSet Name
    known = SortedSet.fromList (keys funs)

    unknown : Name -> Bool
    unknown n = not (contains n known || contains n others)

    isSeed : TailKind -> Bool
    isSeed Pending = True
    isSeed (Passes g) = unknown g
    isSeed Done = False

    seeds : List Name
    seeds = [n | (n, ts) <- SortedMap.toList funs, any isSeed ts]

    -- who passes on the result of `g`
    callers : SortedMap Name (List Name)
    callers = foldl (\m, (n, ts) => foldl (\m', t => case t of
                                                       Passes g => insert g (n :: fromMaybe [] (lookup g m')) m'
                                                       _ => m') m ts) empty (SortedMap.toList funs)

    go : SortedSet Name -> List Name -> SortedSet Name
    go acc [] = acc
    go acc (g :: rest) =
        let new = filter (\c => not (contains c acc)) (fromMaybe [] (lookup g callers))
        in go (foldl (flip insert) acc new) (new ++ rest)

||| The functions of `defs` whose result is never a pending closure: a non-tail
||| call to one needs no trampoline. Only a function defined here can be named.
export
trampolineFree : List (Name, RCDef) -> SortedSet Name
trampolineFree defs =
    let pend = pendingFuns defs
    in SortedSet.fromList (mapMaybe (\(n, d) => case d of
                                                  MkRCFun _ RBoxed _ _ => if contains n pend then Nothing else Just n
                                                  MkRCFun {} => Nothing
                                                  _ => Just n) defs)

||| The boxed calls in `e`, each with whether it sits in a tail position.
sites : Bool -> RCExp -> List (Bool, Name)
sites t (RLet _ _ _ v b) = sites False v ++ sites t b
sites t (RLoop _ _ _ _ k) = sites t k
sites t e =
    let own = case e of
                   RAppName _ _ n _ => [(t, n)]
                   RAppNameRep _ n _ RBoxed _ _ => [(t, n)]
                   _ => []
    in own ++ (case tailChildren e of
                    Just ks => concatMap (sites t) ks
                    Nothing => concatMap (sites False) (children e))

||| For the dump: how many non-tail call sites there are and how many of them
||| call a function that never returns a pending closure, then the C names of
||| those functions.
export
pendingReport : List (Name, RCDef) -> String
pendingReport defs =
    let pend = pendingFuns defs
        okSet = trampolineFree defs
        allSites = concatMap (\(_, d) => case d of
                                              MkRCFun _ _ _ body => sites False body
                                              _ => []) defs
        nonTail = filter (not . fst) allSites
        elidable = filter (\(_, n) => contains n okSet) nonTail
    in unlines (("sites " ++ show (length nonTail) ++ " elidable " ++ show (length elidable))
                :: ("functions " ++ show (length (SortedMap.toList (funTails defs))) ++ " pending " ++ show (length (Prelude.toList pend)))
                :: map cName (Prelude.toList okSet))
