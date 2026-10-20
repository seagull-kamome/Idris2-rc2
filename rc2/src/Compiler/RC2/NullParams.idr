module Compiler.RC2.NullParams

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Which parameters hold the world token or an erased value, and so are
-- always C NULL. See `rc2/doc/null-params.md`.

import Compiler.RC2.RCExp
import Compiler.RC2.Util

import Core.CompileExpr
import Core.Name
import Core.TT

import Data.List
import Data.Maybe
import Data.SortedMap
import Data.SortedSet

%default covering

||| Each element with its position.
export
withIndex : List a -> List (Nat, a)
withIndex = go 0
  where
    go : Nat -> List a -> List (Nat, a)
    go _ [] = []
    go k (x :: xs) = (k, x) :: go (S k) xs

||| The position of `x` in `xs`.
indexOf : Eq a => a -> List a -> Maybe Nat
indexOf x xs = fst <$> find ((== x) . snd) (withIndex xs)

||| `[0 .. n-1]`.
indicesTo : Nat -> List Nat
indicesTo n = map fst (withIndex (replicate n ()))

||| What one `RCExp` says about a function name.
data Fact : Type where
     ||| `RAppName n args`.
     FCall : Name -> List RCLocal -> Fact
     ||| `RUnderApp n _ args`: the first `length args` parameters of `n`.
     FUnder : Name -> List RCLocal -> Fact
     ||| Any `RUnderApp`/`RDelay` of `n` (`FUnder` counts the `RUnderApp`s).
     FMention : Name -> Fact
     ||| A reference that supplies no known arguments: a constant closure, or
     ||| a dual-ABI worker call.
     FEscape : Name -> Fact

factsOf : RCExp -> List Fact
factsOf = foldRCNamesR $ { onAppName       := \n, args => [FCall n args]
                         , onAppNameRep    := \n => [FEscape n]
                         , onUnderApp      := \n => [FMention n]
                         , onUnderAppArgs  := \n, args => [FUnder n args]
                         , onConstClosure  := \n => [FEscape n]
                         } noRCNames

||| One function: its parameter ids and what its body says.
record Fn where
  constructor MkFn
  name : Name
  params : List Int
  facts : List Fact

||| The names some reference to which is not a call or a partial application
||| built from a known argument list: such a function can be entered with
||| arguments this pass never sees.
escaping : List Name -> List Fn -> SortedSet Name
escaping roots fns =
    let (balance, escapes) = foldl step (empty, SortedSet.fromList roots) (concatMap (.facts) fns)
    in foldl (\acc, (n, k) => if k > 0 then insert n acc else acc) escapes (SortedMap.toList balance)
  where
    step : (SortedMap Name Int, SortedSet Name) -> Fact -> (SortedMap Name Int, SortedSet Name)
    step (b, es) (FMention n) = (insert n (fromMaybe 0 (lookup n b) + 1) b, es)
    step (b, es) (FUnder n _) = (insert n (fromMaybe 0 (lookup n b) - 1) b, es)
    step (b, es) (FEscape n) = (b, insert n es)
    step acc (FCall _ _) = acc

||| The state of one parameter in the forward analysis: nothing known yet
||| (the optimistic start), always the given `NativeTy`, or not provable.
data St = Top | Is NativeTy | Bot

Eq St where
    Top == Top = True
    Bot == Bot = True
    Is a == Is b = a == b
    _ == _ = False

||| Two sources agree on a type, or fall back to `TErased` (both are NULL).
meet : St -> St -> St
meet Top x = x
meet x Top = x
meet Bot _ = Bot
meet _ Bot = Bot
meet (Is a) (Is b) = if a == b then Is a else Is TErased

||| Parameter positions (`%foreign` slots, then parameters found to reach
||| one) that are the world by type, so also in a function that escapes. A
||| variable has one type, so a parameter passed at such a position is the
||| world whatever else reads it.
worldPositions : List (Name, RCDef) -> List Fn -> SortedMap Name (SortedSet Nat)
worldPositions defs fns = grow (foldl seed empty defs)
  where
    seed : SortedMap Name (SortedSet Nat) -> (Name, RCDef) -> SortedMap Name (SortedSet Nat)
    seed acc (n, MkRCForeign _ fargs _) =
        let ks = mapMaybe (\(k, t) => case t of
                                           CFWorld => Just k
                                           _ => Nothing) (withIndex fargs)
        in if null ks then acc else insert n (SortedSet.fromList ks) acc
    seed acc _ = acc

    reached : SortedMap Name (SortedSet Nat) -> Fn -> SortedSet Nat
    reached typed g = SortedSet.fromList (concatMap viaFact g.facts)
      where
        viaArgs : Name -> List RCLocal -> List Nat
        viaArgs n args = case lookup n typed of
                              Nothing => []
                              Just ks => mapMaybe (\k => case getAt k args of
                                                              Just (RCLoc v) => indexOf v g.params
                                                              _ => Nothing) (Prelude.toList ks)

        viaFact : Fact -> List Nat
        viaFact (FCall n args) = viaArgs n args
        viaFact (FUnder n args) = viaArgs n args
        viaFact _ = []

    size : SortedMap Name (SortedSet Nat) -> Nat
    size = foldl (\acc, s => acc + length (Prelude.toList s)) 0 . SortedMap.values

    step : SortedMap Name (SortedSet Nat) -> SortedMap Name (SortedSet Nat)
    step typed = foldl (\acc, g => let found = reached typed g
                                   in if null (Prelude.toList found)
                                         then acc
                                         else insert g.name (union found (fromMaybe empty (lookup g.name acc))) acc) typed fns

    grow : SortedMap Name (SortedSet Nat) -> SortedMap Name (SortedSet Nat)
    grow typed = let next = step typed
                 in if size next == size typed then typed else grow next

||| One call or partial application of a function, as its callee sees it.
record Site where
  constructor MkSite
  caller : Name
  under : Bool
  args : List RCLocal

||| For a function never entered with arguments this pass does not see: the
||| type of each parameter that every call and partial application passes
||| as the world or an erased value, or as a parameter that itself is.
||| Starts from "everything is" and removes what a site contradicts, so a
||| parameter handed round a recursion and never anything else stays unknown
||| (`Top`) and is not reported.
forwardStates : SortedMap Name (List Int) -> SortedMap Name (SortedSet Nat) -> SortedMap Name (List Site) -> SortedMap Name (List St)
forwardStates paramsOf typed sites = grow initial
  where
    arityOf : Name -> Nat
    arityOf n = maybe 0 length (lookup n paramsOf)

    initial : SortedMap Name (List St)
    initial = fromList (map (\(n, _) => (n, replicate (arityOf n) Top)) (SortedMap.toList sites))

    worldTyped : Name -> Nat -> Bool
    worldTyped g j = maybe False (contains j) (lookup g typed)

    resolve : SortedMap Name (List St) -> Name -> RCLocal -> St
    resolve _ _ RCWorld = Is (TPrim WorldType)
    resolve _ _ RCErased = Is TErased
    resolve states g (RCLoc v) =
        case lookup g paramsOf >>= indexOf v of
             Nothing => Bot
             Just j => if worldTyped g j
                          then Is (TPrim WorldType)
                          else fromMaybe Bot (lookup g states >>= getAt j)
    resolve _ _ _ = Bot

    atSite : SortedMap Name (List St) -> Nat -> Site -> St
    atSite states i s =
        if s.under && i >= length s.args
           then Bot
           else maybe Bot (resolve states s.caller) (getAt i s.args)

    recompute : SortedMap Name (List St) -> Name -> List Site -> List St
    recompute states n ss =
        map (\i => foldl (\acc, s => meet acc (atSite states i s)) Top ss) (indicesTo (arityOf n))

    grow : SortedMap Name (List St) -> SortedMap Name (List St)
    grow states =
        let next = fromList (map (\(n, ss) => (n, recompute states n ss)) (SortedMap.toList sites))
        in if next == states then states else grow next

||| The parameters of each function that hold NULL, by parameter id: the
||| world (by type, or because every caller passes it) or an erased value
||| (every caller passes it). `roots` are the names called from outside.
export
nullParamTable : (roots : List Name) -> List (Name, RCDef) -> SortedMap Name (SortedMap Int NativeTy)
nullParamTable roots defs =
    let fns = mapMaybe toFn defs
        paramsOf = fromList (map (\g => (g.name, g.params)) fns)
        typed = worldPositions defs fns
        closed = SortedSet.fromList (map (.name) fns) `difference` escaping roots fns
        sites = foldl (addSites closed) empty fns
        states = forwardStates paramsOf typed sites
    in fromList (mapMaybe (entry typed states) fns)
  where
    toFn : (Name, RCDef) -> Maybe Fn
    toFn (n, MkRCFun args _ _ body) =
        if isMutualLoopMerged n then Nothing else Just (MkFn n (map fst args) (factsOf body))
    toFn _ = Nothing

    addSites : SortedSet Name -> SortedMap Name (List Site) -> Fn -> SortedMap Name (List Site)
    addSites closed acc g = foldl add acc g.facts
      where
        add : SortedMap Name (List Site) -> Fact -> SortedMap Name (List Site)
        add m (FCall n args) = if contains n closed then insert n (MkSite g.name False args :: fromMaybe [] (lookup n m)) m else m
        add m (FUnder n args) = if contains n closed then insert n (MkSite g.name True args :: fromMaybe [] (lookup n m)) m else m
        add m _ = m

    entry : SortedMap Name (SortedSet Nat) -> SortedMap Name (List St) -> Fn -> Maybe (Name, SortedMap Int NativeTy)
    entry typed states g =
        let found = mapMaybe (\(j, p) => map (p,) (tyAt j)) (withIndex g.params)
        in if null found then Nothing else Just (g.name, fromList found)
      where
        tyAt : Nat -> Maybe NativeTy
        tyAt j = if maybe False (contains j) (lookup g.name typed)
                    then Just (TPrim WorldType)
                    else case lookup g.name states >>= getAt j of
                              Just (Is ty) => Just ty
                              _ => Nothing
