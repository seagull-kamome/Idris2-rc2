||| Dead argument elimination: a parameter whose only use is being passed
||| on, unchanged, as an argument that is itself dead is removed from the
||| function and from every call. The elaborator hands every `where`
||| function the enclosing clause's variables whether it uses them or
||| not, and a loop that merely carries such a value still holds it
||| until the loop exits. Runs on the named case trees before lambda
||| lifting, so a lambda that only forwarded such a value doesn't
||| capture it. Design: `rc2/doc/dead-args.md`. Disable with
||| `--directive nodeadargs`.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Compiler.RC2.DeadArgs

import Core.CompileExpr
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

||| Per name: how many times it occurs, and the call slots among those
||| occurrences. One walk for the whole body, whatever the number of
||| parameters (`where` functions carry many). A binder never reuses a
||| name in scope, so every occurrence of a parameter's name is that
||| parameter.
Uses : Type
Uses = SortedMap Name (Nat, List Slot)

usesIn : NamedCExp -> Uses
usesIn = go empty
  where
    bump : Uses -> Name -> Maybe Slot -> Uses
    bump acc x s = let (n, ss) = fromMaybe (0, []) (lookup x acc) in insert x (S n, maybe ss (:: ss) s) acc

    mutual
      go : Uses -> NamedCExp -> Uses
      go acc (NmLocal _ x) = bump acc x Nothing
      go acc (NmApp _ (NmRef _ g) args) = foldl arg acc (zip [0 .. length args] args)
        where
          arg : Uses -> (Nat, NamedCExp) -> Uses
          arg a (j, NmLocal _ x) = bump a x (Just (g, j))
          arg a (_, e) = go a e
      go acc (NmLam _ _ b) = go acc b
      go acc (NmLet _ _ v b) = go (go acc v) b
      go acc (NmApp _ f args) = foldl go (go acc f) args
      go acc (NmCon _ _ _ _ args) = foldl go acc args
      go acc (NmOp _ _ args) = foldl go acc (toList args)
      go acc (NmExtPrim _ _ args) = foldl go acc args
      go acc (NmForce _ _ t) = go acc t
      go acc (NmDelay _ _ t) = go acc t
      go acc (NmConCase _ sc alts def) =
          maybe id (flip go) def (foldl (\a, (MkNConAlt _ _ _ _ b) => go a b) (go acc sc) alts)
      go acc (NmConstCase _ sc alts def) =
          maybe id (flip go) def (foldl (\a, (MkNConstAlt _ b) => go a b) (go acc sc) alts)
      go acc _ = acc

||| The slots a parameter reaches when every one of its uses is an
||| argument of a call; `Nothing` if any use is something else.
forwardedTo : Uses -> Name -> Maybe (List Slot)
forwardedTo uses p = case lookup p uses of
    Nothing => Just []
    Just (n, ss) => if length ss == n then Just ss else Nothing

||| Functions whose signature must stay as it is: referenced other than
||| by a call with as many arguments as they take (a bare reference, a
||| `Force` of one, another number of arguments), or a root.
pinned : List Name -> SortedMap Name Nat -> List (Name, NamedDef) -> SortedSet Name
pinned roots arity defs = foldl (\s, (_, d) => defRefs s d) (fromList roots) defs
  where
    mutual
      go : SortedSet Name -> NamedCExp -> SortedSet Name
      go s (NmRef _ g) = insert g s
      go s (NmForce _ _ (NmRef _ g)) = insert g s
      go s (NmApp _ (NmRef _ g) args) =
          foldl go (if lookup g arity == Just (length args) then s else insert g s) args
      go s (NmLam _ _ b) = go s b
      go s (NmLet _ _ v b) = go (go s v) b
      go s (NmApp _ f args) = foldl go (go s f) args
      go s (NmCon _ _ _ _ args) = foldl go s args
      go s (NmOp _ _ args) = foldl go s (toList args)
      go s (NmExtPrim _ _ args) = foldl go s args
      go s (NmForce _ _ t) = go s t
      go s (NmDelay _ _ t) = go s t
      go s (NmConCase _ sc alts def) =
          maybe id (flip go) def (foldl (\a, (MkNConAlt _ _ _ _ b) => go a b) (go s sc) alts)
      go s (NmConstCase _ sc alts def) =
          maybe id (flip go) def (foldl (\a, (MkNConstAlt _ b) => go a b) (go s sc) alts)
      go s _ = s

    defRefs : SortedSet Name -> NamedDef -> SortedSet Name
    defRefs s (MkNmFun _ b) = go s b
    defRefs s (MkNmError b) = go s b
    defRefs s _ = s

||| The dead slots: the greatest set of candidate slots all of whose
||| forwarding targets are themselves in the set. A slot leaves the set
||| through a worklist over reversed edges, so each edge is looked at
||| once however long the forwarding chains are.
deadSlots : SortedSet Name -> List (Name, NamedDef) -> SortedSet Slot
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
    candidates : (Name, NamedDef) -> List (Slot, List Slot)
    candidates (n, MkNmFun args body) =
        if contains n fixed then []
        else let uses = usesIn body
             in mapMaybe (\(i, p) => map (\ts => ((n, i), ts)) (forwardedTo uses p))
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

data Fresh : Type where

||| Drops the dead arguments of every call in `e`. When a dropped
||| argument does work, every argument that does is first bound by a
||| `let`, in order, so each is still evaluated once and in its place.
dropCallArgs : {auto f : Ref Fresh Int} -> SortedMap Name (SortedSet Nat) -> NamedCExp -> Core NamedCExp
dropCallArgs dead = go
  where
    atomic : NamedCExp -> Bool
    atomic (NmLocal _ _) = True
    atomic (NmPrimVal _ _) = True
    atomic (NmErased _) = True
    atomic _ = False

    bindAll : FC -> List NamedCExp -> (List NamedCExp -> NamedCExp) -> Core NamedCExp
    bindAll fc [] k = pure (k [])
    bindAll fc (a :: as) k =
        if atomic a then bindAll fc as (k . (a ::))
        else do
          i <- get Fresh
          put Fresh (i + 1)
          let x = MN "rc2deadArg" i
          NmLet fc x a <$> bindAll fc as (k . (NmLocal fc x ::))

    mutual
      go : NamedCExp -> Core NamedCExp
      go (NmApp fc (NmRef rfc g) args) = do
          args' <- traverse go args
          case lookup g dead of
               Nothing => pure (NmApp fc (NmRef rfc g) args')
               Just ds =>
                   let droppedWork = any (\(i, a) => contains i ds && not (atomic a)) (zip [0 .. length args'] args')
                   in if droppedWork
                         then bindAll fc args' (\as => NmApp fc (NmRef rfc g) (dropAt ds as))
                         else pure (NmApp fc (NmRef rfc g) (dropAt ds args'))
      go (NmLam fc x b) = NmLam fc x <$> go b
      go (NmLet fc x v b) = NmLet fc x <$> go v <*> go b
      go (NmApp fc g args) = NmApp fc <$> go g <*> traverse go args
      go (NmCon fc n ci t args) = NmCon fc n ci t <$> traverse go args
      go (NmOp fc op args) = NmOp fc op <$> traverseVect args
      go (NmExtPrim fc p args) = NmExtPrim fc p <$> traverse go args
      go (NmForce fc lr t) = NmForce fc lr <$> go t
      go (NmDelay fc lr t) = NmDelay fc lr <$> go t
      go (NmConCase fc sc alts def) =
          pure $ NmConCase fc !(go sc)
                    !(traverse (\(MkNConAlt n ci t as b) => MkNConAlt n ci t as <$> go b) alts)
                    !(traverseOpt go def)
      go (NmConstCase fc sc alts def) =
          pure $ NmConstCase fc !(go sc)
                    !(traverse (\(MkNConstAlt c b) => MkNConstAlt c <$> go b) alts)
                    !(traverseOpt go def)
      go e = pure e

      traverseVect : Vect k NamedCExp -> Core (Vect k NamedCExp)
      traverseVect [] = pure []
      traverseVect (a :: as) = pure $ !(go a) :: !(traverseVect as)

||| Removes every dead parameter, and its argument at every call, in
||| `main` and every definition. Whole-program only: another module's
||| calls would be out of sight.
export
applyDeadArgs : {auto c : Ref Ctxt Defs} -> (roots : List Name) -> Maybe NamedCExp -> List (Name, FC, NamedDef)
             -> Core (Maybe NamedCExp, List (Name, FC, NamedDef))
applyDeadArgs roots main defs = do
    let named = map (\(n, _, d) => (n, d)) defs
        arity : SortedMap Name Nat :=
            fromList (mapMaybe (\(n, d) => case d of
                                               MkNmFun args _ => Just (n, length args)
                                               _ => Nothing) named)
    fixed <- logTime 3 "rc2: Dead arguments (pinned)" $
               pure $ pinned roots arity (maybe named (\m => (MN "__mainExpression" 0, MkNmFun [] m) :: named) main)
    slots <- logTime 3 "rc2: Dead arguments (slots)" $ pure $ deadSlots fixed named
    let dead : SortedMap Name (SortedSet Nat) :=
            foldl (\m, (n, i) => insert n (insert i (fromMaybe empty (lookup n m))) m) SortedMap.empty (Prelude.toList slots)
    if null (Prelude.toList slots)
       then pure (main, defs)
       else logTime 3 "rc2: Dead arguments (rewrite)" $ do
         f <- newRef Fresh 0
         main' <- traverseOpt (dropCallArgs dead) main
         defs' <- traverse (\(n, fc, d) => (n, fc,) <$> rewriteDef dead n d) defs
         pure (main', defs')
  where
    rewriteDef : {auto f : Ref Fresh Int} -> SortedMap Name (SortedSet Nat) -> Name -> NamedDef -> Core NamedDef
    rewriteDef dead n (MkNmFun args body) =
        MkNmFun (maybe args (\ds => dropAt ds args) (lookup n dead)) <$> dropCallArgs dead body
    rewriteDef dead _ (MkNmError body) = MkNmError <$> dropCallArgs dead body
    rewriteDef _ _ d = pure d
