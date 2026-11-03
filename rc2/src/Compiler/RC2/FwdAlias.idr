||| Every reference to a function that only calls another with its own
||| parameters, in order, is made to the other, so that dead code elimination
||| drops it. See `rc2/doc/fwd-alias.md`. Disable with
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

||| `f -> g` for each boxed function `f` that is `g` applied to its own
||| parameters in order, with `g` a boxed function of the same arity.
forwarders : List (Name, RCDef) -> SortedMap Name Name
forwarders defs =
    let arities = SortedMap.fromList (mapMaybe arityOf defs)
    in SortedMap.fromList (mapMaybe (target arities) defs)
  where
    arityOf : (Name, RCDef) -> Maybe (Name, Nat)
    arityOf (n, MkRCFun args RBoxed False _) = if all (isBoxed . snd) args then Just (n, length args) else Nothing
    arityOf _ = Nothing

    target : SortedMap Name Nat -> (Name, RCDef) -> Maybe (Name, Name)
    target arities (f, MkRCFun args@(_ :: _) RBoxed False (RAppName _ Nothing g xs)) =
        if g /= f && xs == map (RCLoc . fst) args && all (isBoxed . snd) args && lookup g arities == Just (length args)
           then Just (f, g)
           else Nothing
    target _ _ = Nothing

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
applyFwdAlias defs =
    let fwd = forwarders defs
    in if null fwd
          then defs
          else let final = resolved fwd
               in map (\(n, d) => (n, renameNamesD (renameWith final) d)) defs
