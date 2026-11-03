||| Every reference to a function that only calls another with its own
||| parameters (in order, or in another order for a call and a closure whose
||| missing parameters stay last) is made to the other, so that dead code
||| elimination drops it. See `rc2/doc/fwd-alias.md`. Disable with
||| `--directive nofwdalias`.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Compiler.RC2.FwdAlias

import Compiler.RC2.FunDedup
import Compiler.RC2.RCExp

import Core.Context

import Data.List
import Data.Maybe
import Data.SortedMap
import Data.SortedSet

%default covering

isBoxed : Rep -> Bool
isBoxed RBoxed = True
isBoxed _ = False

||| The arity of each boxed, non-worker function whose parameters are all boxed.
arities : List (Name, RCDef) -> SortedMap Name Nat
arities defs = SortedMap.fromList (mapMaybe arityOf defs)
  where
    arityOf : (Name, RCDef) -> Maybe (Name, Nat)
    arityOf (n, MkRCFun args RBoxed False _) = if all (isBoxed . snd) args then Just (n, length args) else Nothing
    arityOf _ = Nothing

||| `f -> g` for each boxed function `f` that is `g` applied to its own
||| parameters in order, with `g` a boxed function of the same arity.
forwarders : SortedMap Name Nat -> List (Name, RCDef) -> SortedMap Name Name
forwarders arities defs = SortedMap.fromList (mapMaybe target defs)
  where
    target : (Name, RCDef) -> Maybe (Name, Name)
    target (f, MkRCFun args@(_ :: _) RBoxed False (RAppName _ Nothing g xs)) =
        if g /= f && xs == map (RCLoc . fst) args && all (isBoxed . snd) args && lookup g arities == Just (length args)
           then Just (f, g)
           else Nothing
    target _ = Nothing

upTo : Nat -> List Nat
upTo n = reverse (go n)
  where
    go : Nat -> List Nat
    go Z = []
    go (S k) = k :: go k

indexIn : Eq a => a -> List a -> Maybe Nat
indexIn x = go 0
  where
    go : Nat -> List a -> Maybe Nat
    go _ [] = Nothing
    go i (y :: ys) = if x == y then Just i else go (S i) ys

||| `f -> (g, perm)` for each boxed function `f` that is `g` applied to all of
||| its own parameters in another order: argument `j` of `g` is parameter
||| `perm !! j` of `f`.
permuters : SortedMap Name Nat -> List (Name, RCDef) -> SortedMap Name (Name, List Nat)
permuters arities defs = SortedMap.fromList (mapMaybe target defs)
  where
    target : (Name, RCDef) -> Maybe (Name, (Name, List Nat))
    target (f, MkRCFun args@(_ :: _) RBoxed False (RAppName _ Nothing g xs)) =
        let n = length args
            params = map (RCLoc . fst) args
        in case traverse (\x => indexIn x params) xs of
                Just p => if g /= f && length xs == n && all (isBoxed . snd) args
                             && lookup g arities == Just n
                             && sort p == upTo n && p /= upTo n
                             then Just (f, (g, p))
                             else Nothing
                Nothing => Nothing
    target _ = Nothing

||| The closure `partial f missing caps` as `partial g missing caps'`, when
||| the captured prefix of `f`'s parameters is a prefix of `g`'s too and the
||| missing ones stay last, in order. `perm` is a permutation.
permClosure : (perm : List Nat) -> (missing : Nat) -> (caps : List RCLocal) -> Maybe (List RCLocal)
permClosure perm missing caps =
    let k = length caps
        n = length perm
        rest = drop k perm
    in if k + missing /= n || rest /= drop k (upTo n)
          then Nothing
          else traverse (\j => getAt j caps) (take k perm)

||| Every closure of a function that calls another with its parameters in
||| another order, and every call of it, made to the other function.
permRewrite : SortedMap Name (Name, List Nat) -> RCExp -> RCExp
permRewrite ps e =
    case mapChildren (permRewrite ps) e of
         e'@(RUnderApp fc f m caps) =>
             case lookup f ps of
                  Just (g, perm) => maybe e' (RUnderApp fc g m) (permClosure perm m caps)
                  Nothing => e'
         e'@(RAppName fc Nothing f xs) =>
             case lookup f ps of
                  Just (g, perm) => if length xs /= length perm then e'
                                       else maybe e' (RAppName fc Nothing g) (traverse (\j => getAt j xs) perm)
                  Nothing => e'
         e' => e'

permRewriteD : SortedMap Name (Name, List Nat) -> RCDef -> RCDef
permRewriteD ps (MkRCFun args r w body) = MkRCFun args r w (permRewrite ps body)
permRewriteD ps (MkRCError body) = MkRCError (permRewrite ps body)
permRewriteD _ d = d

||| Follows `f -> g -> h` to the end, for at most `fuel` steps; a cycle stays
||| where it is.
resolve : (fuel : Nat) -> SortedMap Name Name -> Name -> Name
resolve Z _ n = n
resolve (S k) fwd n =
    case lookup n fwd of
         Nothing => n
         Just m => if reaches k m n then n else resolve k fwd m
  where
    reaches : Nat -> Name -> Name -> Bool
    reaches Z _ _ = True
    reaches (S j) cur target = case lookup cur fwd of
                                    Nothing => False
                                    Just next => next == target || reaches j next target

||| What each forwarder resolves to, computed once.
resolved : SortedMap Name Name -> SortedMap Name Name
resolved fwd =
    let entries = SortedMap.toList fwd
        fuel = length entries + 1
    in SortedMap.fromList (map (\(f, _) => (f, resolve fuel fwd f)) entries)

renameWith : SortedMap Name Name -> Name -> Name
renameWith final n = fromMaybe n (lookup n final)

||| Every reference to a forwarder made to its target.
export
applyFwdAlias : List (Name, RCDef) -> List (Name, RCDef)
applyFwdAlias defs0 =
    let ars = arities defs0
        ps = permuters ars defs0
        defs = if null ps then defs0 else map (\(n, d) => (n, permRewriteD ps d)) defs0
        fwd = forwarders ars defs
    in if null fwd
          then defs
          else let final = resolved fwd
               in map (\(n, d) => (n, renameNamesD (renameWith final) d)) defs
