||| Pushing a `case` into the tails of the value it scrutinises.
||| `let v = <branching value> in case v of ...`, where `v` is read by
||| nothing else, becomes the branching value with the `case` moved
||| into each of its tails. A tail that builds a constructor (or is a
||| constant) meets only its own alt there, as a single-alt `case` on a
||| fresh local that `Compiler.RC2.ConstFold`'s known-constructor fold
||| then removes -- so the constructor is never built. This is
||| case-of-case for inner arms that merely *end* in a constructor,
||| the `Core` `do`-block bind chain. See
||| `rc2/doc/constructor-escape-analysis.md`'s "Rewrite B". Disable
||| with `--directive nopushcon`.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Compiler.RC2.PushCon

import Compiler.RC2.ConstFold
import Compiler.RC2.LateInline
import Compiler.RC2.Loop
import Compiler.RC2.RCExp
import Compiler.RC2.Util

import Core.CompileExpr
import Core.Context
import Core.Core
import Core.FC
import Core.TT

import Data.DPair
import Data.Fin
import Data.List
import Data.Maybe
import Data.SortedMap
import Data.SortedSet

%default covering

-------------------------------------------------------------------------------
-- Size budget
-- Same scale as `Compiler.RC2.Inline`'s `caseOfCaseSizeBudget` and
-- `smallBodyThreshold`, see rc2/doc/inlining.md's "Size budget".

||| Most nodes one push may add, over the consumer it replaces.
pushSizeBudget : Nat
pushSizeBudget = 200

||| An alt larger than this may land in at most one tail.
bigAltThreshold : Nat
bigAltThreshold = 24

sizeOf : RCExp -> Nat
sizeOf (RLet _ _ _ value body) = 1 + sizeOf value + sizeOf body
sizeOf (RCmpCase _ _ _ _ t f) = 1 + sizeOf t + sizeOf f
sizeOf (RConCase _ _ alts mDef) =
    1 + sum (map (\(MkRConAlt _ _ _ _ b) => sizeOf b) alts) + maybe 0 sizeOf mDef
sizeOf (RConstCase _ _ alts mDef) =
    1 + sum (map (\(MkRConstAlt _ b) => sizeOf b) alts) + maybe 0 sizeOf mDef
sizeOf _ = 1

-------------------------------------------------------------------------------
-- Tails

||| Rebuilds `e` with every tail replaced. A tail is where `e`'s value
||| is produced: past `RLet`'s value, into every arm of a branch.
mapTails : (RCExp -> Core RCExp) -> RCExp -> Core RCExp
mapTails f (RLet fc v r value body) = RLet fc v r value <$> mapTails f body
mapTails f (RCmpCase fc op args pd t e) = do
    t' <- mapTails f t
    e' <- mapTails f e
    pure (RCmpCase fc op args pd t' e')
mapTails f (RConCase fc sc alts mDef) = do
    alts' <- traverse (\(MkRConAlt n ci t as b) => MkRConAlt n ci t as <$> mapTails f b) alts
    mDef' <- traverseOpt (mapTails f) mDef
    pure (RConCase fc sc alts' mDef')
mapTails f (RConstCase fc sc alts mDef) = do
    alts' <- traverse (\(MkRConstAlt c b) => MkRConstAlt c <$> mapTails f b) alts
    mDef' <- traverseOpt (mapTails f) mDef
    pure (RConstCase fc sc alts' mDef')
mapTails f e = f e

tailsOf : RCExp -> List RCExp
tailsOf = go
  where
    go : RCExp -> List RCExp
    go (RLet _ _ _ _ body) = go body
    go (RCmpCase _ _ _ _ t f) = go t ++ go f
    go (RConCase _ _ alts mDef) =
        concatMap (\(MkRConAlt _ _ _ _ b) => go b) alts ++ maybe [] go mDef
    go (RConstCase _ _ alts mDef) =
        concatMap (\(MkRConstAlt _ b) => go b) alts ++ maybe [] go mDef
    go t = [t]

-------------------------------------------------------------------------------
-- The consumer

||| The `case` a pushed tail meets.
data Consumer = ConC FC (List RConAlt) (Maybe RCExp)
              | ConstC FC (List RConstAlt) (Maybe RCExp)

||| Which part of the consumer one tail lands on: `Just i` is alt `i`
||| (the default being index `length alts`), `Nothing` the whole
||| consumer, for a tail whose value isn't known here.
Landing : Type
Landing = Maybe (Maybe Nat)

||| `Nothing`: the tail never produces a value (`RCrash`), so nothing
||| lands on it.
landingOf : Consumer -> RCExp -> Maybe Landing
landingOf _ (RCrash _ _) = Nothing
landingOf (ConC _ alts mDef) t =
    Just $ case knownTag t of
                Just (n, tag) => Just (altIndex n tag)
                Nothing => Nothing
  where
    knownTag : RCExp -> Maybe (Name, Maybe Int)
    knownTag (RCon _ n _ tag _ Nothing) = Just (n, tag)
    knownTag (RV _ (RCConstCon n _ tag _)) = Just (n, tag)
    knownTag (RV _ (RCEmptyCon n _ tag)) = Just (n, Just tag)
    knownTag _ = Nothing

    matches : Name -> Maybe Int -> RConAlt -> Bool
    matches n tag (MkRConAlt n' _ tag' _ _) = if isJust tag then tag == tag' else n == n'

    altIndex : Name -> Maybe Int -> Maybe Nat
    altIndex n tag =
        maybe (map (const (length alts)) mDef) Just (finToNat <$> findIndex (matches n tag) alts)
landingOf (ConstC _ alts mDef) t =
    Just $ case knownConst t of
                Just c => Just (maybe (map (const (length alts)) mDef) Just
                                      (findIndex (\(MkRConstAlt c' _) => c == c') alts >>= \i => Just (finToNat i)))
                Nothing => Nothing
  where
    knownConst : RCExp -> Maybe Constant
    knownConst (RPrimVal _ c) = Just c
    knownConst (RV _ (RCConst c)) = Just c
    knownConst _ = Nothing

||| Sizes of the consumer's parts, alts first, then the default.
partSizes : Consumer -> List Nat
partSizes (ConC _ alts mDef) = map (\(MkRConAlt _ _ _ _ b) => sizeOf b) alts ++ maybe [] (\d => [sizeOf d]) mDef
partSizes (ConstC _ alts mDef) = map (\(MkRConstAlt _ b) => sizeOf b) alts ++ maybe [] (\d => [sizeOf d]) mDef

||| Whether pushing is worth it and within budget, given where each
||| tail lands. Worth it only if some tail is known (and a `Just
||| Nothing` -- known, but matching no part -- is a tail that can't
||| return, as good as `RCrash`).
pushOk : Consumer -> List Landing -> Bool
pushOk consumer landings =
    let sizes = partSizes consumer
        whole = sum sizes
        partCount = \i => length (filter (landsOn i) landings)
        added = sum (map landedSize landings)
        bigTwice = any (\(i, s) => s > bigAltThreshold && partCount i > 1) (zip [0 .. length sizes] sizes)
    in any isJust landings && not bigTwice && added <= whole + pushSizeBudget
  where
    landsOn : Nat -> Landing -> Bool
    landsOn _ Nothing = True
    landsOn i (Just (Just j)) = i == j
    landsOn _ (Just Nothing) = False

    landedSize : Landing -> Nat
    landedSize Nothing = sum (partSizes consumer)
    landedSize (Just (Just j)) = fromMaybe 0 (getAt j (partSizes consumer))
    landedSize (Just Nothing) = 0

-------------------------------------------------------------------------------
-- The rewrite

||| `copy` with every id it binds freshened, and `v` renamed to `v'`.
freshCopy : {auto vid : Ref VarId Int} -> (v : Int) -> (v' : Int) -> RCExp -> Core RCExp
freshCopy v v' e = do
    ren <- freshenBoundIds (collectBoundIds e)
    pure (renameRCExp (insert v v' ren) e)

||| One tail, with the consumer (or just the part it lands on) moved
||| into it as a `case` on a fresh local bound to the tail.
pushInto : {auto vid : Ref VarId Int} -> Int -> Rep -> Consumer -> RCExp -> Core RCExp
pushInto v rep consumer t =
    case landingOf consumer t of
         Nothing => pure t
         Just landing => do
             v' <- freshVarId
             body <- freshCopy v v' (consumerFor v landing)
             pure (RLet (fcOf consumer) v' rep t body)
  where
    fcOf : Consumer -> FC
    fcOf (ConC fc _ _) = fc
    fcOf (ConstC fc _ _) = fc

    consumerFor : Int -> Landing -> RCExp
    consumerFor v Nothing = case consumer of
        ConC fc alts mDef => RConCase fc (RCLoc v) alts mDef
        ConstC fc alts mDef => RConstCase fc (RCLoc v) alts mDef
    consumerFor v (Just part) = case consumer of
        ConC fc alts mDef =>
            case part >>= \i => getAt i alts of
                 Just alt => RConCase fc (RCLoc v) [alt] Nothing
                 Nothing => maybe (RCrash fc "[rc2] PushCon: known tail matched no alt") id mDef
        ConstC fc alts mDef =>
            case part >>= \i => getAt i alts of
                 Just (MkRConstAlt _ b) => b
                 Nothing => maybe (RCrash fc "[rc2] PushCon: known tail matched no alt") id mDef

||| `v` is read nowhere in the consumer's own parts.
consumerAvoids : Int -> Consumer -> Bool
consumerAvoids v consumer = null (ownedUsedIn (singleton (RCLoc v)) (asExp consumer))
  where
    asExp : Consumer -> RCExp
    asExp (ConC fc alts mDef) = RConCase fc RCNull alts mDef
    asExp (ConstC fc alts mDef) = RConstCase fc RCNull alts mDef

||| Bottom-up over the whole body. The `Bool` is whether anything was
||| pushed, so only changed definitions get refolded.
pushExp : {auto vid : Ref VarId Int} -> RCExp -> Core (RCExp, Bool)
pushExp (RLet fc v rep value body) = do
    (value', c1) <- pushExp value
    (body', c2) <- pushExp body
    let unchanged = pure (RLet fc v rep value' body', c1 || c2)
    case consumerOf v body' of
         Nothing => unchanged
         Just consumer =>
             let tails = tailsOf value'
             in if length tails < 2 || not (consumerAvoids v consumer)
                   then unchanged
                   else if pushOk consumer (mapMaybe (landingOf consumer) tails)
                           then do value'' <- mapTails (pushInto v rep consumer) value'
                                   pure (value'', True)
                           else unchanged
  where
    consumerOf : Int -> RCExp -> Maybe Consumer
    consumerOf v (RConCase cfc (RCLoc s) alts mDef) = if s == v then Just (ConC cfc alts mDef) else Nothing
    consumerOf v (RConstCase cfc (RCLoc s) alts mDef) = if s == v then Just (ConstC cfc alts mDef) else Nothing
    consumerOf _ _ = Nothing
pushExp (RCmpCase fc op args pd t f) = do
    (t', c1) <- pushExp t
    (f', c2) <- pushExp f
    pure (RCmpCase fc op args pd t' f', c1 || c2)
pushExp (RConCase fc sc alts mDef) = do
    alts' <- traverse (\(MkRConAlt n ci tag as b) => do (b', c) <- pushExp b; pure (MkRConAlt n ci tag as b', c)) alts
    mDef' <- traverseOpt pushExp mDef
    pure (RConCase fc sc (map fst alts') (map fst mDef'), any snd alts' || maybe False snd mDef')
pushExp (RConstCase fc sc alts mDef) = do
    alts' <- traverse (\(MkRConstAlt c b) => do (b', ch) <- pushExp b; pure (MkRConstAlt c b', ch)) alts
    mDef' <- traverseOpt pushExp mDef
    pure (RConstCase fc sc (map fst alts') (map fst mDef'), any snd alts' || maybe False snd mDef')
pushExp e = pure (e, False)

||| Every definition, with each changed one refolded so the
||| single-alt `case`s this leaves on known tails are folded away.
export
applyPushCon : {auto vid : Ref VarId Int} -> List (Name, RCDef) -> Core (List (Name, RCDef))
applyPushCon = traverse pushDef
  where
    pushDef : (Name, RCDef) -> Core (Name, RCDef)
    pushDef (n, MkRCFun args retRep isWorker body) = do
        (body', changed) <- pushExp body
        pure (n, if changed then foldConstDef True empty (MkRCFun args retRep isWorker body') else MkRCFun args retRep isWorker body)
    pushDef d = pure d
