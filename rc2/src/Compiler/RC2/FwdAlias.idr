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
import Data.Nat
import Decidable.Equality
import Data.SortedMap
import Data.SortedSet
import Data.Vect

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

||| One argument of a forwarding call: a parameter of the forwarder, by position, or a constant.
data Slot = Param Nat | Fixed RCLocal

isFixed : Slot -> Bool
isFixed (Fixed _) = True
isFixed _ = False

isConstant : RCLocal -> Bool
isConstant (RCLoc _) = False
isConstant _ = True

||| The slots of a forwarding call of `f` (parameters `params`): every argument is a parameter
||| of `f` or a constant, and every parameter is passed once.
slotsOf : List RCLocal -> List RCLocal -> Maybe (List Slot)
slotsOf params xs = traverse slotOf xs >>= check
  where
    slotOf : RCLocal -> Maybe Slot
    slotOf x = case indexIn x params of
                    Just j => Just (Param j)
                    Nothing => if isConstant x then Just (Fixed x) else Nothing

    paramOf : Slot -> Maybe Nat
    paramOf (Param j) = Just j
    paramOf (Fixed _) = Nothing

    check : List Slot -> Maybe (List Slot)
    check ss = if sort (mapMaybe paramOf ss) == upTo (length params) then Just ss else Nothing

||| The arguments of the call a forwarder makes, with the parameters taken from `xs`.
fillSlots : List Slot -> List RCLocal -> Maybe (List RCLocal)
fillSlots ss xs = traverse (\s => case s of
                                      Param j => getAt j xs
                                      Fixed c => Just c) ss

||| `f -> (g, slots)` for each boxed, non-worker `f` whose body is one `RAppName` of a boxed `g`, with
||| every parameter of `f` passed once and the other arguments constants, at least one (the cases
||| above take the others).
constForwarders : SortedMap Name Nat -> List (Name, RCDef) -> SortedMap Name (Name, List Slot)
constForwarders arities defs = SortedMap.fromList (mapMaybe target defs)
  where
    target : (Name, RCDef) -> Maybe (Name, (Name, List Slot))
    target (f, MkRCFun args@(_ :: _) RBoxed False (RAppName _ Nothing g xs)) =
        case slotsOf (map (RCLoc . fst) args) xs of
             Just ss => if g /= f && all (isBoxed . snd) args && lookup g arities == Just (length xs) && any isFixed ss
                           then Just (f, (g, ss))
                           else Nothing
             Nothing => Nothing
    target _ = Nothing

sameRep : Rep -> Rep -> Bool
sameRep RBoxed RBoxed = True
sameRep (RNative a) (RNative b) = a == b
sameRep (RInlineNative a) (RInlineNative b) = a == b
sameRep (RRet n l) (RRet m k) = case decEq n m of
                                     Yes Refl => l == k
                                     No _ => False
sameRep _ _ = False

record RepFwd where
  constructor MkRepFwd
  target : Name
  argReps : List Rep
  retRep : Rep
  slots : List Slot

||| `f -> ..` for each function `f` (a worker too) whose body is one `RAppNameRep` of another function, with
||| no `postDrop`, the result in the same representation as `f`'s own, every parameter passed once
||| in its own representation, and the other arguments constants.
repForwarders : List (Name, RCDef) -> SortedMap Name RepFwd
repForwarders defs = SortedMap.fromList (mapMaybe target defs)
  where
    okAt : List (Int, Rep) -> (Slot, Rep) -> Bool
    okAt args (Param j, r) = maybe False (\pr => sameRep (snd pr) r) (getAt j args)
    okAt _ (Fixed _, _) = True

    paramRepsOk : List (Int, Rep) -> List Slot -> List Rep -> Bool
    paramRepsOk args ss reps = all (okAt args) (zip ss reps)

    target : (Name, RCDef) -> Maybe (Name, RepFwd)
    target (f, MkRCFun args@(_ :: _) ret _ (RAppNameRep _ g reps rr [] xs)) =
        case slotsOf (map (RCLoc . fst) args) xs of
             Just ss => if g /= f && sameRep ret rr && paramRepsOk args ss reps
                           then Just (f, MkRepFwd g reps rr ss)
                           else Nothing
             Nothing => Nothing
    target _ = Nothing

||| Every call of a function that only forwards, with constants added, made a call of its target
||| (`constForwarders` for `RAppName`, `repForwarders` for `RAppNameRep`). A closure keeps the
||| function: what a later `apply` supplies would not land where the target takes it.
constRewrite : SortedMap Name (Name, List Slot) -> SortedMap Name RepFwd -> RCExp -> RCExp
constRewrite cs rs e =
    case mapChildren (constRewrite cs rs) e of
         e'@(RAppName fc Nothing f xs) =>
             case lookup f cs of
                  Just (g, ss) => maybe e' (RAppName fc Nothing g) (fillSlots ss xs)
                  Nothing => e'
         e'@(RAppNameRep fc f ar rr pd xs) =>
             case lookup f rs of
                  Just fw => if sameRep rr fw.retRep
                                then fromMaybe e' (fillSlots fw.slots xs >>= repCall fc fw.target fw.argReps rr pd)
                                else e'
                  Nothing => e'
         e' => e'

constRewriteD : SortedMap Name (Name, List Slot) -> SortedMap Name RepFwd -> RCDef -> RCDef
constRewriteD cs rs (MkRCFun args r w body) = MkRCFun args r w (constRewrite cs rs body)
constRewriteD cs rs (MkRCError body) = MkRCError (constRewrite cs rs body)
constRewriteD _ _ d = d

||| `constRewrite` a few times over, so that a forwarder of a forwarder is followed.
constRounds : Nat -> SortedMap Name Nat -> List (Name, RCDef) -> List (Name, RCDef)
constRounds Z _ defs = defs
constRounds (S k) ars defs =
    let cs = constForwarders ars defs
        rs = repForwarders defs
    in if null cs && null rs
          then defs
          else constRounds k ars (map (\(n, d) => (n, constRewriteD cs rs d)) defs)

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
        defsP = if null ps then defs0 else map (\(n, d) => (n, permRewriteD ps d)) defs0
        defs = constRounds 4 ars defsP
        fwd = forwarders ars defs
    in if null fwd
          then defs
          else let final = resolved fwd
               in map (\(n, d) => (n, renameNamesD (renameWith final) d)) defs
