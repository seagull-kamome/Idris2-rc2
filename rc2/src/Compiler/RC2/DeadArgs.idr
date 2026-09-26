||| Dead argument elimination: a parameter whose only use is being passed
||| on, unchanged, as an argument that is itself dead is removed from the
||| function and from every call. The elaborator hands every `where`
||| function the enclosing clause's variables whether it uses them or
||| not, and a loop that merely carries such a value still holds it
||| until the loop exits. Design: `rc2/doc/dead-args.md`. Disable with
||| `--directive nodeadargs`.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Compiler.RC2.DeadArgs

import Compiler.RC2.RCExp

import Core.Context
import Core.Context.Log
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
-- Analysis

||| A parameter: the function and its 0-based position.
Slot : Type
Slot = (Name, Nat)

||| Per local: how many times it occurs, and the call slots among those
||| occurrences. One walk for the whole body, whatever the number of
||| parameters (`where` functions carry many).
Uses : Type
Uses = SortedMap Int (Nat, List Slot)

usesIn : RCExp -> Uses
usesIn = go empty
  where
    one : Uses -> RCLocal -> Uses
    one acc (RCLoc i) = let (n, ss) = fromMaybe (0, []) (lookup i acc) in insert i (S n, ss) acc
    one acc _ = acc

    many : Uses -> List RCLocal -> Uses
    many = foldl one

    slot : Uses -> (Slot, RCLocal) -> Uses
    slot acc (s, RCLoc i) = let (n, ss) = fromMaybe (0, []) (lookup i acc) in insert i (S n, s :: ss) acc
    slot acc _ = acc

    go : Uses -> RCExp -> Uses
    go acc (RV _ v) = one acc v
    go acc (RAppName _ _ g args) = foldl slot acc (zip (map (\j => (g, j)) [0 .. length args]) args)
    go acc (RUnderApp _ _ _ args) = many acc args
    go acc (RApp _ _ c args) = many acc (c :: args)
    go acc (RLet _ _ _ value body) = go (go acc value) body
    go acc (RCon _ _ _ _ args _) = many acc args
    go acc (RRetPack _ _ _ fields) = many acc fields
    go acc (ROp _ _ _ args pd) = many (many acc (toList args)) pd
    go acc (RExtPrim _ _ _ args pd) = many (many acc args) pd
    go acc (RStructGet _ sv _ _ pd) = many (one acc sv) pd
    go acc (RStructSet _ sv _ _ v pd) = many (many acc [sv, v]) pd
    go acc (RFill _ c _ v pd) = many (many acc [c, v]) pd
    go acc (RCmpCase _ _ args pd t f) = go (go (many (many acc (toList args)) pd) t) f
    go acc (RConCase _ sc alts mDef) =
        maybe id (flip go) mDef (foldl (\a, (MkRConAlt _ _ _ _ b) => go a b) (one acc sc) alts)
    go acc (RConstCase _ sc alts mDef) =
        maybe id (flip go) mDef (foldl (\a, (MkRConstAlt _ b) => go a b) (one acc sc) alts)
    go acc (RMemoize _ _ _ body) = go acc body
    go acc e = if null (SortedSet.toList (freeLocalsR e)) then acc else many acc (SortedSet.toList (freeLocalsR e))

||| The slots a parameter reaches when every one of its uses is an
||| argument of a call; `Nothing` if any use is something else.
forwardedTo : Uses -> Int -> Maybe (List Slot)
forwardedTo uses p = case lookup p uses of
    Nothing => Just []
    Just (n, ss) => if length ss == n then Just ss else Nothing

||| Functions whose signature must stay as it is: referenced as a value
||| (a partial application, a constant closure, a worker call), called
||| with some other number of arguments, or a root.
pinned : List Name -> SortedMap Name Nat -> List (Name, RCDef) -> SortedSet Name
pinned roots arity defs =
    let refs = foldr (\(_, d), acc => foldRCNamesD
                  ({ onUnderApp := \n => [n]
                   , onConstClosure := \n => [n]
                   , onAppNameRep := \n => [n]
                   , onAppName := \n, args => if lookup n arity == Just (length args) then [] else [n]
                   } noRCNames) d ++ acc) roots defs
    in fromList refs

||| The dead slots: the greatest set of candidate slots all of whose
||| forwarding targets are themselves in the set. A slot leaves the set
||| through a worklist over reversed edges, so each edge is looked at
||| once however long the forwarding chains are.
deadSlots : SortedSet Name -> List (Name, RCDef) -> SortedSet Slot
deadSlots fixed defs =
    -- `foldr (++)`, not `concatMap`: that is a left fold of `++`,
    -- quadratic over the whole program.
    let cands : SortedMap Slot (List Slot) := fromList (foldr (++) [] (map candidates defs))
        preds : SortedMap Slot (List Slot) :=
            foldl (\m, (s, ts) => foldl (\m', t => insert t (s :: fromMaybe [] (lookup t m')) m') m ts) SortedMap.empty
                  (SortedMap.toList cands)
        broken = filter (\(_, ts) => any (\t => isNothing (lookup t cands)) ts) (SortedMap.toList cands)
    in fromList (keys (evict preds (map fst broken) cands))
  where
    candidates : (Name, RCDef) -> List (Slot, List Slot)
    candidates (n, MkRCFun args _ _ body) =
        if contains n fixed then []
        else let uses = usesIn body
             in mapMaybe (\(i, (p, _)) => map (\ts => ((n, i), ts)) (forwardedTo uses p))
                         (zip [0 .. length args] args)
    candidates _ = []

    evict : SortedMap Slot (List Slot) -> List Slot -> SortedMap Slot (List Slot) -> SortedMap Slot (List Slot)
    evict _ [] live = live
    evict preds (s :: rest) live =
        if isNothing (lookup s live) then evict preds rest live
        else evict preds (fromMaybe [] (lookup s preds) ++ rest) (delete s live)

-------------------------------------------------------------------------------
-- Rewrite

dropAt : SortedSet Nat -> List a -> List a
dropAt ds xs = map snd (filter (\(i, _) => not (contains i ds)) (zip [0 .. length xs] xs))

||| Drops the dead arguments of every call in `e`.
dropCallArgs : SortedMap Name (SortedSet Nat) -> RCExp -> RCExp
dropCallArgs dead = go
  where
    go : RCExp -> RCExp
    go e@(RAppName fc lazy n args) = maybe e (\ds => RAppName fc lazy n (dropAt ds args)) (lookup n dead)
    go (RLet fc v rep value body) = RLet fc v rep (go value) (go body)
    go (RCmpCase fc op args pd t f) = RCmpCase fc op args pd (go t) (go f)
    go (RConCase fc sc alts mDef) =
        RConCase fc sc (map (\(MkRConAlt n ci tag as b) => MkRConAlt n ci tag as (go b)) alts) (map go mDef)
    go (RConstCase fc sc alts mDef) =
        RConstCase fc sc (map (\(MkRConstAlt c b) => MkRConstAlt c (go b)) alts) (map go mDef)
    go (RMemoize fc n rep body) = RMemoize fc n rep (go body)
    go e = e

||| Removes every dead parameter, and its argument at every call.
export
applyDeadArgs : {auto c : Ref Ctxt Defs} -> (roots : List Name) -> List (Name, RCDef) -> Core (List (Name, RCDef))
applyDeadArgs roots defs = do
    arity <- pure $ the (SortedMap Name Nat) $
                fromList (mapMaybe (\(n, d) => case d of
                                                   MkRCFun args _ _ _ => Just (n, length args)
                                                   _ => Nothing) defs)
    fixed <- logTime 3 "rc2: Dead arguments (pinned)" $ pure (pinned roots arity defs)
    slots <- logTime 3 "rc2: Dead arguments (slots)" $ pure (deadSlots fixed defs)
    dead <- pure $ the (SortedMap Name (SortedSet Nat)) $
                foldl (\m, (n, i) => insert n (insert i (fromMaybe empty (lookup n m))) m) SortedMap.empty (SortedSet.toList slots)
    if null (SortedSet.toList slots)
       then pure defs
       else logTime 3 "rc2: Dead arguments (rewrite)" $ pure (map (rewriteDef dead) defs)
  where
    rewriteDef : SortedMap Name (SortedSet Nat) -> (Name, RCDef) -> (Name, RCDef)
    rewriteDef dead (n, MkRCFun args ret w body) =
        let args' = maybe args (\ds => dropAt ds args) (lookup n dead)
        in (n, MkRCFun args' ret w (dropCallArgs dead body))
    rewriteDef dead (n, MkRCError body) = (n, MkRCError (dropCallArgs dead body))
    rewriteDef _ nd = nd
