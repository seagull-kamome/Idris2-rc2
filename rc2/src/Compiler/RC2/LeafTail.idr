||| A tail call to a known function is made directly instead of through a
||| closure for the nearest trampoline to run, unless the call stays inside
||| one strongly connected component of the tail-call graph. See
||| `rc2/doc/leaf-tail-calls.md`. Disable with `--directive noleaftail`.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Compiler.RC2.LeafTail

import Compiler.RC2.Emit.Util
import Compiler.RC2.MutualLoop
import Compiler.RC2.RCExp
import Compiler.RC2.Util

import Core.Context

import Data.List
import Data.SortedMap
import Data.SortedSet

%default covering

||| The functions whose body `e` ends in a call: a direct tail call to a
||| boxed function or to a worker, through a loop as well.
tailCallees : RCExp -> List Name
tailCallees (RAppName _ _ n _) = [n]
tailCallees (RAppNameRep _ n _ _ _ _) = [n]
tailCallees (RLoop _ _ _ _ k) = tailCallees k
tailCallees e = maybe [] (concatMap tailCallees) (tailChildren e)

||| `e` with each tail call of an eligible function made direct. Loops are
||| entered; their `RLoopContinue` is not a call.
rewriteTails : (Name -> List RCLocal -> Bool) -> RCExp -> Core RCExp
rewriteTails ok = go
  where
    go : RCExp -> Core RCExp
    go e@(RAppName fc _ n args) =
        pure (if ok n args then RAppNameRep fc n (map (const RBoxed) args) RBoxed [] args {sameLen = lengthMap args} else e)
    go (RLoop {sameLen} fc ps initial pd k) = RLoop fc ps initial pd <$> go k
    go e = fromMaybe (pure e) (traverseTailChildren @{Applicative.CORE} go e)

||| The tail-call graph over the functions of `defs`.
tailGraph : List (Name, RCDef) -> Graph
tailGraph defs =
    let known = SortedSet.fromList (mapMaybe (\(n, d) => case d of
                                                         MkRCFun {} => Just n
                                                         _ => Nothing) defs)
    in SortedMap.fromList (mapMaybe (\(n, d) => case d of
                                                     MkRCFun _ _ _ body => Just (n, SortedSet.fromList (filter (\c => contains c known) (tailCallees body)))
                                                     _ => Nothing) defs)

||| The number of the strongly connected component of each function.
componentOf : Graph -> SortedMap Name Nat
componentOf graph =
    let sccs = tarjanSCCs graph
    in SortedMap.fromList (concat (zipWith (\i, ns => map (\n => (n, i)) ns) [0 .. length sccs] sccs))

||| The boxed entry points a direct call can name, with their arity.
entryArities : List (Name, RCDef) -> SortedMap Name Nat
entryArities defs =
    SortedMap.fromList (mapMaybe (\(n, d) => case d of
                                                 MkRCFun as RBoxed False _ =>
                                                     if length as > 0 && length as <= MaxExtractFunArgs
                                                        then Just (n, length as)
                                                        else Nothing
                                                 _ => Nothing) defs)

||| Whether `caller` may call `n` with `args` directly: a boxed entry of that
||| arity, in a component other than the caller's.
directOk : SortedMap Name Nat -> SortedMap Name Nat -> Name -> Name -> List RCLocal -> Bool
directOk comps entries caller n args =
    case (lookup n entries, lookup caller comps, lookup n comps) of
         (Just arity, Just a, Just b) => length args == arity && a /= b
         _ => False

||| Make the tail calls that cannot close a cycle direct, in every definition.
export
applyLeafTail : List (Name, RCDef) -> Core (List (Name, RCDef))
applyLeafTail defs = go (componentOf (tailGraph defs)) (entryArities defs)
  where
    go : SortedMap Name Nat -> SortedMap Name Nat -> Core (List (Name, RCDef))
    go comps entries =
        traverse (\(n, d) => case d of
                                   MkRCFun as RBoxed isWorker body =>
                                       (\b => (n, MkRCFun as RBoxed isWorker b)) <$> rewriteTails (directOk comps entries n) body
                                   _ => pure (n, d)) defs
