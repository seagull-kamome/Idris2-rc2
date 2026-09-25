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
import Data.Vect

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
-- The post-RC wrappers count too: nearly every post-RC alt starts with
-- them, and sizing one as 1 let a large alt be copied freely.
sizeOf (RDup _ _ _ k) = 1 + sizeOf k
sizeOf (RDrop _ _ k) = 1 + sizeOf k
sizeOf (RFree _ _ k) = 1 + sizeOf k
sizeOf (RReleaseReuse _ _ k) = 1 + sizeOf k
sizeOf (RReuseOffer _ _ _ _ k) = 1 + sizeOf k
sizeOf (RLoop _ _ _ _ k) = 1 + sizeOf k
sizeOf (RMemoize _ _ _ k) = 1 + sizeOf k
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
-- Post-RC only (`applyPushConRC`): ownership wrappers pass the tail
-- through, a loop is opaque (its exits sit next to `RLoopContinue`s
-- and loop-converted native shadows), and a `continue` is never a tail.
mapTails f (RDup fc v n k) = RDup fc v n <$> mapTails f k
mapTails f (RDrop fc vs k) = RDrop fc vs <$> mapTails f k
mapTails f (RFree fc v k) = RFree fc v <$> mapTails f k
mapTails f (RReleaseReuse fc v k) = RReleaseReuse fc v <$> mapTails f k
mapTails f (RReuseOffer fc sc ds us k) = RReuseOffer fc sc ds us <$> mapTails f k
mapTails f e@(RLoopContinue {}) = pure e
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
    go (RDup _ _ _ k) = go k
    go (RDrop _ _ k) = go k
    go (RFree _ _ k) = go k
    go (RReleaseReuse _ _ k) = go k
    go (RReuseOffer _ _ _ _ k) = go k
    go (RLoopContinue {}) = []
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
    knownTag (RCon _ n _ tag _ _) = Just (n, tag)
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

-------------------------------------------------------------------------------
-- After RC annotation: the same push, with each known tail folded by hand
-- The shapes `LateInline` creates after RC annotation. Each fold moves
-- ownership explicitly; see constructor-escape-analysis.md, "What is
-- left after Early inline, and the RC-aware fold".


||| `v`'s cell reservation handed to `w`, or dropped when there is no `w`.
retargetReuse : Int -> Maybe RCLocal -> RCExp -> RCExp
retargetReuse v w (RCon fc n ci tag args (Just (RCLoc r))) =
    if r == v then RCon fc n ci tag args w else RCon fc n ci tag args (Just (RCLoc r))
retargetReuse v w (RReleaseReuse fc (RCLoc r) k) =
    if r == v then maybe (retargetReuse v w k) (\w' => RReleaseReuse fc w' (retargetReuse v w k)) w
              else RReleaseReuse fc (RCLoc r) (retargetReuse v w k)
retargetReuse v w e = mapChildren (retargetReuse v w) e

||| Removes one element equal to `x`, if any.
removeOne : Int -> List Int -> (Bool, List Int)
removeOne x [] = (False, [])
removeOne x (y :: ys) = if x == y then (True, ys) else let (b, ys') = removeOne x ys in (b, y :: ys')

||| The alt body `p` for a tail constructor built from `args` (already
||| renamed into `p`) with cell `reuseFrom`, without that constructor or
||| the scrutinee `v`: `Nothing` when `v`'s release isn't in `p`'s
||| straight-line prologue in a shape this handles.
foldAlt : FC -> Int -> List Int -> Maybe RCLocal -> RCExp -> Maybe RCExp
foldAlt fc v pending reuseFrom p = go pending p
  where
    drops : List Int -> RCExp -> RCExp
    drops [] k = k
    drops is k = RDrop fc (map RCLoc is) k

    locId : RCLocal -> Maybe Int
    locId (RCLoc i) = Just i
    locId _ = Nothing

    releaseTail : RCExp -> RCExp
    releaseTail k = maybe k (\w => RReleaseReuse fc w k) reuseFrom

    go : List Int -> RCExp -> Maybe RCExp
    -- A field `dup`'d before `v` goes was taking its own reference; the
    -- constructor's is handed over instead.
    go pend (RDup dfc x@(RCLoc i) n k) =
        let (hit, pend') = removeOne i pend
        in if not hit then RDup dfc x n <$> go pend k
           else case n of
                     Z => go pend' k
                     S m => RDup dfc x m <$> go pend' k
    go pend (RDrop dfc vs k) =
        if elem (RCLoc v) vs
           then let rest = filter (/= RCLoc v) vs
                in Just $ (if null rest then id else RDrop dfc rest) (drops pend (releaseTail k))
           else RDrop dfc vs <$> go pend k
    go pend (RReuseOffer rfc (RCLoc s) ds us k) =
        if s == v && pend == pending
           then Just $ drops (mapMaybe locId us) (retargetReuse v reuseFrom k)
           else RReuseOffer rfc (RCLoc s) ds us <$> go pend k
    go pend (RFree ffc x k) = RFree ffc x <$> go pend k
    go pend (RReleaseReuse rfc x k) = RReleaseReuse rfc x <$> go pend k
    go _ _ = Nothing

isNativeRep : Rep -> Bool
isNativeRep RBoxed = False
isNativeRep _ = True

||| One tail, post-RC. A constructor tail whose fields are all Boxed
||| locals is folded against its alt (`foldAlt`); anything else gets the
||| part of the consumer it lands on, on a fresh local, as `pushInto`.
pushIntoRC : {auto vid : Ref VarId Int} -> SortedMap Int Rep -> Int -> Rep -> Consumer -> RCExp -> Core RCExp
pushIntoRC reps v rep consumer t =
    case (consumer, landingOf consumer t, t) of
         (ConC fc alts _, Just (Just (Just i)), RCon tfc _ _ _ args reuseFrom) =>
             case (getAt i alts, traverse boxedLoc args) of
                  (Just alt, Just argIds) => do
                      -- Freshen the alt's own binders (its fields included)
                      -- while keeping `v`, which the fold removes.
                      RConCase _ _ [MkRConAlt _ _ _ fields body] _ <- freshCopy v v (RConCase fc (RCLoc v) [alt] Nothing)
                          | _ => pushInto v rep consumer t
                      let ren = SortedMap.fromList (zip fields argIds)
                      case foldAlt tfc v argIds reuseFrom (renameRCExp ren body) of
                           Just folded => pure folded
                           Nothing => pushInto v rep consumer t
                  _ => pushInto v rep consumer t
         _ => pushInto v rep consumer t
  where
    boxedLoc : RCLocal -> Maybe Int
    boxedLoc (RCLoc j) = if maybe False isNativeRep (lookup j reps) then Nothing else Just j
    boxedLoc _ = Nothing

||| Every `Rep` bound by an `RLet` or a loop anywhere in `e`: a tail's own
||| fields can be locals bound inside the value it ends.
letReps : SortedMap Int Rep -> RCExp -> SortedMap Int Rep
letReps acc (RLet _ v r value body) = letReps (letReps (insert v r acc) value) body
letReps acc (RLoop _ ps _ _ k) = letReps (foldl (\m, (i, r) => insert i r m) acc ps) k
letReps acc e = foldl letReps acc (children e)

||| As `pushExp`, post-RC: `v` may only be released or reused by the
||| consumer (`onlyReleased`), and a single tail is enough (shape A is
||| a one-tail value). `reps` tracks each local's `Rep` on the way down.
pushExpRC : {auto vid : Ref VarId Int} -> SortedMap Int Rep -> RCExp -> Core (RCExp, Bool)
pushExpRC reps (RLet fc v rep value body) = do
    let reps' = insert v rep reps
    (value', c1) <- pushExpRC reps value
    (body', c2) <- pushExpRC reps' body
    let unchanged = pure (RLet fc v rep value' body', c1 || c2)
    case body' of
         RConCase cfc (RCLoc s) alts mDef =>
             let consumer = ConC cfc alts mDef
                 tails = tailsOf value'
                 landings = mapMaybe (landingOf consumer) tails
             in if s /= v || not (all (onlyReleased v) (children body'))
                   || not (any isKnown landings) || not (pushOk consumer landings)
                   then unchanged
                   else do value'' <- mapTails (pushIntoRC (letReps reps value') v rep consumer) value'
                           pure (value'', True)
         _ => unchanged
  where
    isKnown : Landing -> Bool
    isKnown (Just (Just _)) = True
    isKnown _ = False
pushExpRC reps (RLoop fc ps initial pd k) = do
    (k', c) <- pushExpRC (foldl (\m, (i, r) => insert i r m) reps ps) k
    pure (RLoop fc ps initial pd k', c)
pushExpRC reps e = do
    results <- traverse (pushExpRC reps) (children e)
    pure (rebuild e (map fst results), any snd results)
  where
    -- `children`'s order, put back.
    rebuild : RCExp -> List RCExp -> RCExp
    rebuild (RCmpCase fc op args pd _ _) [t, f] = RCmpCase fc op args pd t f
    rebuild (RConCase fc sc alts mDef) ks =
        let (altKs, defK) = splitAt (length alts) ks
        in RConCase fc sc (zipWith (\(MkRConAlt n ci t as _), b => MkRConAlt n ci t as b) alts altKs) (map (const (fromMaybe (RCrash fc "") (head' defK))) mDef)
    rebuild (RConstCase fc sc alts mDef) ks =
        let (altKs, defK) = splitAt (length alts) ks
        in RConstCase fc sc (zipWith (\(MkRConstAlt c _), b => MkRConstAlt c b) alts altKs) (map (const (fromMaybe (RCrash fc "") (head' defK))) mDef)
    rebuild (RDup fc x n _) [k] = RDup fc x n k
    rebuild (RDrop fc vs _) [k] = RDrop fc vs k
    rebuild (RFree fc x _) [k] = RFree fc x k
    rebuild (RReleaseReuse fc x _) [k] = RReleaseReuse fc x k
    rebuild (RReuseOffer fc sc ds us _) [k] = RReuseOffer fc sc ds us k
    rebuild (RMemoize fc n r _) [k] = RMemoize fc n r k
    rebuild e _ = e

||| The post-RC stage, run after `LateInline`.
export
applyPushConRC : {auto vid : Ref VarId Int} -> List (Name, RCDef) -> Core (List (Name, RCDef))
applyPushConRC = traverse pushDef
  where
    pushDef : (Name, RCDef) -> Core (Name, RCDef)
    pushDef (n, MkRCFun args retRep isWorker body) = do
        (body', _) <- pushExpRC (SortedMap.fromList args) body
        pure (n, MkRCFun args retRep isWorker body')
    pushDef d = pure d
