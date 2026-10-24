||| Which parameters hold the world token or an erased value, and so are
||| always C NULL. See `rc2/doc/null-params.md`.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Compiler.RC2.NullParams

import Compiler.RC2.RCExp
import Compiler.RC2.Types
import Compiler.RC2.Util

import Core.CompileExpr
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

||| Each name of the program numbered once: comparing `Name`s is what the
||| fixpoints below would otherwise spend their time on.
numberNames : List Name -> SortedMap Name Int
numberNames = snd . foldl (\(k, m), n => (k + 1, insert n k m)) (the Int 0, empty)

||| One function: its number, parameter ids and what its body says.
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
    let (balance, escapes) = foldl tally (empty, SortedSet.fromList (mapMaybe (\r => lookup r ids) roots))
                                   (foldr (\g, acc => g.facts ++ acc) [] fns)
    in foldl (\acc, (n, k) => if k > 0 then insert n acc else acc) escapes (SortedMap.toList balance)
  where
    count : Int -> Name -> SortedMap Int Int -> SortedMap Int Int
    count d n b = maybe b (\i => insert i (fromMaybe 0 (lookup i b) + d) b) (lookup n ids)

    tally : (SortedMap Int Int, SortedSet Int) -> Fact -> (SortedMap Int Int, SortedSet Int)
    tally (b, es) = \case
        FMention n => (count 1 n b, es)
        FUnder n _ => (count (-1) n b, es)
        FEscape n => (b, maybe es (\i => insert i es) (lookup n ids))
        FCall _ _ => (b, es)

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
sitesOf ids g =
    let paramIx : SortedMap Int Nat := fromList [ (p, k) | (k, p) <- withIndex g.params ]
        arg : RCLocal -> Arg := \case
            RCWorld => AWorld
            RCErased => AErased
            RCLoc v => maybe AOther AParam (lookup v paramIx)
            _ => AOther
        site : Bool -> Name -> List RCLocal -> Maybe Site :=
            \under, n, args => map (\c => MkSite g.ident c under (map arg args)) (lookup n ids)
    in mapMaybe (\case
                     FCall n args => site False n args
                     FUnder n args => site True n args
                     _ => Nothing) g.facts

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
worldPositions ids defs sites =
    let seeds : SortedMap Int (SortedSet Nat) := foldl (\acc => \case
            (n, MkRCForeign _ fargs _) =>
                case (lookup n ids, mapMaybe (\case
                                                 (k, CFWorld) => Just k
                                                 _ => Nothing) (withIndex fargs)) of
                     (Just i, ks@(_ :: _)) => insert i (SortedSet.fromList ks) acc
                     _ => acc
            _ => acc) SortedMap.empty defs
        -- (caller, callee, [(argument position, caller's parameter position)])
        -- for the sites that pass a parameter on
        links : List (Int, Int, List (Nat, Nat)) :=
            mapMaybe (\s => case mapMaybe (\case
                                             (k, AParam j) => Just (k, j)
                                             _ => Nothing) (withIndex s.args) of
                                 [] => Nothing
                                 kjs => Just (s.caller, s.callee, kjs)) sites
    in grow links seeds
  where
    size : SortedMap Int (SortedSet Nat) -> Nat
    size m = sum (map (length . Prelude.toList) (SortedMap.values m))

    grow : List (Int, Int, List (Nat, Nat)) -> SortedMap Int (SortedSet Nat) -> SortedMap Int (SortedSet Nat)
    grow links typed =
        let next := foldl (\acc, (g, n, kjs) =>
                              case lookup n typed of
                                   Nothing => acc
                                   Just ks => case [ j | (k, j) <- kjs, contains k ks ] of
                                                   [] => acc
                                                   js => insertWith union g (SortedSet.fromList js) acc) typed links
        in if size next == size typed then typed else grow links next

||| For a function never entered with arguments this pass does not see: the
||| type of each parameter that every call and partial application passes
||| as the world or an erased value, or as a parameter that itself is.
||| Starts from "everything is" and removes what a site contradicts, so a
||| parameter handed round a recursion and never anything else stays unknown
||| (`Top`) and is not reported.
forwardStates : SortedMap Int Nat -> SortedMap Int (SortedSet Nat) -> SortedMap Int (List Site) -> SortedMap Int (List St)
forwardStates arityOf typed sites =
    grow (fromList [ (n, replicate (arity n) Top) | (n, _) <- SortedMap.toList sites ])
  where
    arity : Int -> Nat
    arity n = fromMaybe 0 (lookup n arityOf)

    atSite : SortedMap Int (List St) -> Nat -> Site -> St
    atSite states i s =
        if s.under && i >= length s.args
           then Bot
           else maybe Bot (the (Arg -> St) $ \case
                               AWorld => Is worldTy
                               AErased => Is TErased
                               AParam j => if maybe False (contains j) (lookup s.caller typed)
                                              then Is worldTy
                                              else fromMaybe Bot (lookup s.caller states >>= getAt j)
                               AOther => Bot) (getAt i s.args)

    grow : SortedMap Int (List St) -> SortedMap Int (List St)
    grow states =
        let next := fromList [ (n, [ foldl (\acc, s => meet acc (atSite states i s)) Top ss | i <- indicesTo (arity n) ])
                             | (n, ss) <- SortedMap.toList sites ]
        in if next == states then states else grow next

||| The parameters of each function that hold NULL, by parameter id: the
||| world (by type, or because every caller passes it) or an erased value
||| (every caller passes it). `roots` are the names called from outside.
export
nullParamTable : (roots : List Name) -> List (Name, RCDef) -> SortedMap Name (SortedMap Int NativeTy)
nullParamTable roots defs =
    let ids : SortedMap Name Int := numberNames (map fst defs)
        fns : List Fn := mapMaybe (\case
                                       (n, MkRCFun args _ _ body) =>
                                           if isMutualLoopMerged n
                                              then Nothing
                                              else map (\i => MkFn i n (map fst args) (factsOf body)) (lookup n ids)
                                       _ => Nothing) defs
        sites : List Site := foldr (\g, acc => sitesOf ids g ++ acc) [] fns
        typed : SortedMap Int (SortedSet Nat) := worldPositions ids defs sites
        closed : SortedSet Int := SortedSet.fromList (map (.ident) fns) `difference` escaping ids roots fns
        closedSites : SortedMap Int (List Site) :=
            foldl (\acc, s => if contains s.callee closed
                                 then insert s.callee (s :: fromMaybe [] (lookup s.callee acc)) acc
                                 else acc) SortedMap.empty sites
        states : SortedMap Int (List St) :=
            forwardStates (fromList (map (\g => (g.ident, length g.params)) fns)) typed closedSites
    in fromList (mapMaybe (entry typed states) fns)
  where
    entry : SortedMap Int (SortedSet Nat) -> SortedMap Int (List St) -> Fn -> Maybe (Name, SortedMap Int NativeTy)
    entry typed states g =
        case mapMaybe (\(j, p) => map (p,) (typeAt j)) (withIndex g.params) of
             [] => Nothing
             found => Just (g.name, fromList found)
      where
        typeAt : Nat -> Maybe NativeTy
        typeAt j = if maybe False (contains j) (lookup g.ident typed)
                      then Just worldTy
                      else case lookup g.ident states >>= getAt j of
                                Just (Is ty) => Just ty
                                _ => Nothing
