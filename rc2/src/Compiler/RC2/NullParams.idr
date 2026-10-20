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

||| Each name of the program numbered once.
numberNames : List Name -> SortedMap Name Int
numberNames = snd . foldl (\(k, m), n => (k + 1, insert n k m)) (the Int 0, empty)

||| One function: its identity (the names of the program, numbered once, as
||| comparing `Name`s is what a fixpoint over every call would spend its time
||| on), its parameter ids and what its body says.
record Fn where
  constructor MkFn
  ident : Int
  name : Name
  params : List Int
  facts : List Fact

||| The functions some reference to which is not a call or a partial
||| application built from a known argument list: such a function can be
||| entered with arguments this pass never sees.
escaping : SortedMap Name Int -> List Name -> List Fn -> SortedSet Int
escaping ids roots fns =
    let (balance, escapes) = foldl step (empty, SortedSet.fromList (mapMaybe (\r => lookup r ids) roots)) (foldr (\g, acc => g.facts ++ acc) [] fns)
    in foldl (\acc, (n, k) => if k > 0 then insert n acc else acc) escapes (SortedMap.toList balance)
  where
    count : Int -> Name -> SortedMap Int Int -> SortedMap Int Int
    count d n b = case lookup n ids of
                       Nothing => b
                       Just i => insert i (fromMaybe 0 (lookup i b) + d) b

    step : (SortedMap Int Int, SortedSet Int) -> Fact -> (SortedMap Int Int, SortedSet Int)
    step (b, es) (FMention n) = (count 1 n b, es)
    step (b, es) (FUnder n _) = (count (-1) n b, es)
    step (b, es) (FEscape n) = (b, maybe es (\i => insert i es) (lookup n ids))
    step acc (FCall _ _) = acc

||| What one argument of a call is, as far as this pass cares.
data Arg = AWorld | AErased | AParam Nat | AOther

||| A call or partial application inside `caller`, its arguments classified
||| once (the fixpoints below visit every site many times).
record Site where
  constructor MkSite
  caller : Int
  callee : Int
  under : Bool
  args : List Arg

sitesOf : SortedMap Name Int -> Fn -> List Site
sitesOf ids g = mapMaybe site g.facts
  where
    paramIx : SortedMap Int Nat
    paramIx = fromList (map (\(k, p) => (p, k)) (withIndex g.params))

    arg : RCLocal -> Arg
    arg RCWorld = AWorld
    arg RCErased = AErased
    arg (RCLoc v) = maybe AOther AParam (lookup v paramIx)
    arg _ = AOther

    make : Bool -> Name -> List RCLocal -> Maybe Site
    make under n args = map (\c => MkSite g.ident c under (map arg args)) (lookup n ids)

    site : Fact -> Maybe Site
    site (FCall n args) = make False n args
    site (FUnder n args) = make True n args
    site _ = Nothing

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
worldPositions : SortedMap Name Int -> List (Name, RCDef) -> List Site -> SortedMap Int (SortedSet Nat)
worldPositions ids defs sites = grow (foldl seed empty defs)
  where
    seed : SortedMap Int (SortedSet Nat) -> (Name, RCDef) -> SortedMap Int (SortedSet Nat)
    seed acc (n, MkRCForeign _ fargs _) =
        let ks = mapMaybe (\(k, t) => case t of
                                           CFWorld => Just k
                                           _ => Nothing) (withIndex fargs)
        in case lookup n ids of
                Just i => if null ks then acc else insert i (SortedSet.fromList ks) acc
                Nothing => acc
    seed acc _ = acc

    ||| (caller, callee, [(argument position, caller's parameter position)]), for
    ||| the sites that pass a parameter on.
    links : List (Int, Int, List (Nat, Nat))
    links = mapMaybe link sites
      where
        link : Site -> Maybe (Int, Int, List (Nat, Nat))
        link s = case mapMaybe (\(k, a) => case a of
                                                AParam j => Just (k, j)
                                                _ => Nothing) (withIndex s.args) of
                      [] => Nothing
                      kjs => Just (s.caller, s.callee, kjs)

    size : SortedMap Int (SortedSet Nat) -> Nat
    size = foldl (\acc, s => acc + length (Prelude.toList s)) 0 . SortedMap.values

    step : SortedMap Int (SortedSet Nat) -> SortedMap Int (SortedSet Nat)
    step typed = foldl add typed links
      where
        add : SortedMap Int (SortedSet Nat) -> (Int, Int, List (Nat, Nat)) -> SortedMap Int (SortedSet Nat)
        add acc (g, n, kjs) =
            case lookup n typed of
                 Nothing => acc
                 Just ks => case filter (\(k, _) => contains k ks) kjs of
                                 [] => acc
                                 found => insert g (foldl (flip insert) (fromMaybe empty (lookup g acc)) (map snd found)) acc

    grow : SortedMap Int (SortedSet Nat) -> SortedMap Int (SortedSet Nat)
    grow typed = let next = step typed
                 in if size next == size typed then typed else grow next

||| For a function never entered with arguments this pass does not see: the
||| type of each parameter that every call and partial application passes
||| as the world or an erased value, or as a parameter that itself is.
||| Starts from "everything is" and removes what a site contradicts, so a
||| parameter handed round a recursion and never anything else stays unknown
||| (`Top`) and is not reported.
forwardStates : SortedMap Int Nat -> SortedMap Int (SortedSet Nat) -> SortedMap Int (List Site) -> SortedMap Int (List St)
forwardStates arityOf typed sites = grow initial
  where
    initial : SortedMap Int (List St)
    initial = fromList (map (\(n, _) => (n, replicate (fromMaybe 0 (lookup n arityOf)) Top)) (SortedMap.toList sites))

    worldTyped : Int -> Nat -> Bool
    worldTyped g j = maybe False (contains j) (lookup g typed)

    resolve : SortedMap Int (List St) -> Int -> Arg -> St
    resolve _ _ AWorld = Is (TPrim WorldType)
    resolve _ _ AErased = Is TErased
    resolve states g (AParam j) =
        if worldTyped g j
           then Is (TPrim WorldType)
           else fromMaybe Bot (lookup g states >>= getAt j)
    resolve _ _ AOther = Bot

    atSite : SortedMap Int (List St) -> Nat -> Site -> St
    atSite states i s =
        if s.under && i >= length s.args
           then Bot
           else maybe Bot (resolve states s.caller) (getAt i s.args)

    recompute : SortedMap Int (List St) -> Int -> List Site -> List St
    recompute states n ss =
        map (\i => foldl (\acc, s => meet acc (atSite states i s)) Top ss) (indicesTo (fromMaybe 0 (lookup n arityOf)))

    grow : SortedMap Int (List St) -> SortedMap Int (List St)
    grow states =
        let next = fromList (map (\(n, ss) => (n, recompute states n ss)) (SortedMap.toList sites))
        in if next == states then states else grow next

||| The sites that call one of the `closed` functions, by callee.
closedSitesOf : SortedSet Int -> List Site -> SortedMap Int (List Site)
closedSitesOf closed = foldl add empty
  where
    add : SortedMap Int (List Site) -> Site -> SortedMap Int (List Site)
    add acc s =
        if contains s.callee closed
           then insert s.callee (s :: fromMaybe [] (lookup s.callee acc)) acc
           else acc

||| The answer, from the two analyses' results. Its inputs are parameters, not
||| local `let`s: a `let` used once is inlined into the closure `mapMaybe`
||| calls per function, and the fixpoint behind it would run once per function.
collect : SortedMap Int (SortedSet Nat) -> SortedMap Int (List St) -> List Fn -> SortedMap Name (SortedMap Int NativeTy)
collect typed states fns = fromList (mapMaybe entry fns)
  where
    entry : Fn -> Maybe (Name, SortedMap Int NativeTy)
    entry g =
        let found = mapMaybe (\(j, p) => map (p,) (tyAt g j)) (withIndex g.params)
        in if null found then Nothing else Just (g.name, fromList found)
      where
        tyAt : Fn -> Nat -> Maybe NativeTy
        tyAt f j = if maybe False (contains j) (lookup f.ident typed)
                      then Just (TPrim WorldType)
                      else case lookup f.ident states >>= getAt j of
                                Just (Is ty) => Just ty
                                _ => Nothing

||| The analyses over the functions `fns`, whose `sites` are known.
analyse : SortedMap Name Int -> List Name -> List (Name, RCDef) -> List Fn -> List Site -> SortedMap Name (SortedMap Int NativeTy)
analyse ids roots defs fns sites =
    let typed = worldPositions ids defs sites
        closed = SortedSet.fromList (map (.ident) fns) `difference` escaping ids roots fns
    in collect typed (forwardStates (arities fns) typed (closedSitesOf closed sites)) fns
  where
    arities : List Fn -> SortedMap Int Nat
    arities = fromList . map (\g => (g.ident, length g.params))

||| The parameters of each function that hold NULL, by parameter id: the
||| world (by type, or because every caller passes it) or an erased value
||| (every caller passes it). `roots` are the names called from outside.
export
nullParamTable : (roots : List Name) -> List (Name, RCDef) -> SortedMap Name (SortedMap Int NativeTy)
nullParamTable roots defs = withIds (numberNames (map fst defs))
  where
    toFn : SortedMap Name Int -> (Name, RCDef) -> Maybe Fn
    toFn ids (n, MkRCFun args _ _ body) =
        if isMutualLoopMerged n
           then Nothing
           else map (\i => MkFn i n (map fst args) (factsOf body)) (lookup n ids)
    toFn _ _ = Nothing

    withFns : SortedMap Name Int -> List Fn -> SortedMap Name (SortedMap Int NativeTy)
    withFns ids fns = analyse ids roots defs fns (foldr (\g, acc => sitesOf ids g ++ acc) [] fns)

    withIds : SortedMap Name Int -> SortedMap Name (SortedMap Int NativeTy)
    withIds ids = withFns ids (mapMaybe (toFn ids) defs)
