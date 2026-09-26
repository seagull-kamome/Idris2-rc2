||| Difference lists carried by a self-recursive function: a parameter
||| extended with `c . (y ::)` on every recursive call and applied once
||| at the end is kept as a chain of cells with an open hole instead of
||| a chain of closures, so extending and applying it are both O(1) and
||| use no stack. Design, eligibility and pipeline position:
||| `rc2/doc/closure-accumulator.md`. Disable with `--directive noctx`.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Compiler.RC2.ClosureCtx

import Compiler.RC2.Emit.Util
import Compiler.RC2.RCExp
import Compiler.RC2.Util

import Core.CompileExpr
import Core.Core
import Core.FC
import Core.Context

import Data.Fin
import Data.List
import Data.Maybe
import Data.SortedMap
import Data.SortedSet
import Data.Vect

%default covering

-------------------------------------------------------------------------------
-- Lambdas that extend a context

||| `L caps.. x = let cell = C fields; apply c [cell]`: `x` fills field
||| `hole` of `C`, and `c` is the capture at position `cPos`.
record Extender where
  constructor MkExtender
  params : List Int
  cPos : Nat
  con : (FC, Name, ConInfo, Maybe Int)
  fields : List RCLocal
  hole : Nat

heapCon : ConInfo -> Bool
heapCon DATACON = True
heapCon CONS = True
heapCon JUST = True
heapCon RECORD = True
heapCon _ = False

extenderOf : SortedSet Name -> RCDef -> Maybe Extender
extenderOf newtypes (MkRCFun params _ False
                      (RLet _ cell _ (RCon fc n ci tag fields Nothing)
                            (RApp _ Nothing (RCLoc c) [RCLoc cell']))) = do
    let ids = map fst params
    guard (cell == cell' && heapCon ci && not (contains n newtypes))
    x <- last' ids
    cPos <- findIndex (== c) ids
    guard (c /= x)
    [hole] <- pure (findIndices (== RCLoc x) fields)
        | _ => Nothing
    guard (all (\f => case f of
                          RCLoc i => i /= c && elem i ids
                          _ => True) fields)
    pure (MkExtender ids (finToNat cPos) (fc, n, ci, tag) fields hole)
extenderOf _ _ = Nothing

||| The extender's cell for one site, `x` left as the hole.
cellFor : Extender -> List RCLocal -> RCExp
cellFor e caps =
    let (fc, n, ci, tag) = e.con
        sub : SortedMap Int RCLocal
        sub = fromList (zip e.params caps)
        field = \f => case f of
                          RCLoc i => fromMaybe RCNull (SortedMap.lookup i sub)
                          _ => f
    in RCon fc n ci tag (map field e.fields) Nothing

-------------------------------------------------------------------------------
-- Finding a context parameter

||| One use of the parameter `c` along a body's tail spine.
data Use = Extend Int | Apply | Pass

mentions : Int -> RCExp -> Bool
mentions c e = contains (RCLoc c) (freeLocalsR e)

||| Whether `c` (parameter `j` of `f`) is used only as a context:
||| extended at self tail calls, passed unchanged at self tail calls,
||| applied at most once per path and never after that. Returns the
||| extension sites (their let-bound partials) on success.
contextSites : Name -> Nat -> Int -> SortedMap Name Extender -> RCExp -> Maybe (SortedMap Int (Name, List RCLocal))
contextSites f j c exts body = go empty body
  where
    selfArgOk : SortedMap Int (Name, List RCLocal) -> List RCLocal -> Maybe (SortedMap Int (Name, List RCLocal))
    selfArgOk pending args = do
        a <- getAt j args
        guard (length (filter (== RCLoc c) args) == (if a == RCLoc c then 1 else 0))
        case a of
             RCLoc v => if v == c then pure empty
                        else map (singleton v) (lookup v pending)
             _ => Nothing

    go : SortedMap Int (Name, List RCLocal) -> RCExp -> Maybe (SortedMap Int (Name, List RCLocal))
    go pending (RLet _ v _ value rest) = case value of
        RUnderApp _ l 1 caps =>
            case lookup l exts of
                 Just e =>
                     if getAt e.cPos caps == Just (RCLoc c)
                        && length (filter (== RCLoc c) caps) == 1
                        && countUsesR (RCLoc v) rest == 1
                        then do r <- go (insert v (l, caps) pending) rest
                                -- The partial must reach a self call, or `c` escapes in it.
                                guard (isJust (lookup v r))
                                pure r
                        else if mentions c value then Nothing else go pending rest
                 Nothing => if mentions c value then Nothing else go pending rest
        RApp _ Nothing (RCLoc c') [a] =>
            if c' == c
               then if a /= RCLoc c && not (mentions c rest) then go pending rest else Nothing
               else if mentions c value then Nothing else go pending rest
        _ => if mentions c value then Nothing else go pending rest
    go pending (RAppName _ Nothing g args) =
        if g == f then selfArgOk pending args
        else if any (== RCLoc c) args then Nothing else pure empty
    go _ (RApp _ Nothing (RCLoc c') [a]) =
        if c' == c && a /= RCLoc c then pure empty
        else if a == RCLoc c then Nothing else pure empty
    go pending (RCmpCase _ _ args _ t e) =
        if any (== RCLoc c) (toList args) then Nothing else mergeLeft <$> go pending t <*> go pending e
    go pending (RConCase _ sc alts mDef) =
        if sc == RCLoc c then Nothing
        else foldl (\acc, (MkRConAlt _ _ _ _ b) => mergeLeft <$> acc <*> go pending b)
                   (maybe (pure empty) (go pending) mDef) alts
    go pending (RConstCase _ sc alts mDef) =
        if sc == RCLoc c then Nothing
        else foldl (\acc, (MkRConstAlt _ b) => mergeLeft <$> acc <*> go pending b)
                   (maybe (pure empty) (go pending) mDef) alts
    go _ e = if mentions c e then Nothing else pure empty

-------------------------------------------------------------------------------
-- Rewriting

data Mode = Entry | Acc Int Int

rewriteBody : {auto v : Ref VarId Int} -> Name -> Name -> Nat -> Int -> Nat
           -> SortedMap Name Extender -> SortedMap Int (Name, List RCLocal) -> Mode -> RCExp -> Core RCExp
rewriteBody f f' j c k exts sites mode = go
  where
    fill : FC -> Int -> RCLocal -> RCExp -> Core RCExp
    fill fc last value rest = do
        u <- freshVarId
        pure $ RLet fc u RBoxed (RFill fc (RCLoc last) k value []) rest

    replaceAt : Nat -> RCLocal -> List RCLocal -> List RCLocal
    replaceAt _ _ [] = []
    replaceAt Z x (_ :: xs) = x :: xs
    replaceAt (S n) x (y :: ys) = y :: replaceAt n x ys

    applied : FC -> RCLocal -> Core RCExp
    applied fc a = case mode of
        Entry => pure (RApp fc Nothing (RCLoc c) [a])
        Acc res last => fill fc last a (RApp fc Nothing (RCLoc c) [RCLoc res])

    go : RCExp -> Core RCExp
    go (RLet fc v rep value rest) = case lookup v sites of
        Just (l, caps) => case lookup l exts of
            Just e => do
                rest' <- go rest
                case mode of
                     Entry => pure (RLet fc v RBoxed (cellFor e caps) rest')
                     Acc _ last => RLet fc v RBoxed (cellFor e caps) <$> fill fc last (RCLoc v) rest'
            Nothing => RLet fc v rep value <$> go rest
        Nothing => case value of
            RApp afc Nothing (RCLoc c') [a] =>
                if c' == c then RLet fc v rep <$> applied afc a <*> go rest
                else RLet fc v rep value <$> go rest
            _ => RLet fc v rep value <$> go rest
    go e@(RAppName fc Nothing g args) =
        if g /= f then pure e
        else case getAt j args of
            Just (RCLoc v) =>
                if v == c
                   then case mode of
                             Entry => pure e
                             Acc res last => pure (RAppName fc Nothing f' (args ++ [RCLoc res, RCLoc last]))
                   else let args' = replaceAt j (RCLoc c) args
                        in case mode of
                                Entry => pure (RAppName fc Nothing f' (args' ++ [RCLoc v, RCLoc v]))
                                Acc res _ => pure (RAppName fc Nothing f' (args' ++ [RCLoc res, RCLoc v]))
            _ => pure e
    go e@(RApp fc Nothing (RCLoc c') [a]) = if c' == c then applied fc a else pure e
    go (RCmpCase fc op args pd t e) = RCmpCase fc op args pd <$> go t <*> go e
    go (RConCase fc sc alts mDef) =
        RConCase fc sc <$> traverse (\(MkRConAlt n ci tag as b) => MkRConAlt n ci tag as <$> go b) alts
                       <*> traverseOpt go mDef
    go (RConstCase fc sc alts mDef) =
        RConstCase fc sc <$> traverse (\(MkRConstAlt cv b) => MkRConstAlt cv <$> go b) alts
                         <*> traverseOpt go mDef
    go e = pure e

-------------------------------------------------------------------------------
-- Whole program

||| The first parameter of `f` that qualifies as a context, with its
||| extension sites and the hole's field index.
contextParam : Name -> List (Int, Rep) -> SortedMap Name Extender -> RCExp -> Maybe (Nat, Int, Nat, SortedMap Int (Name, List RCLocal))
contextParam f params exts body = 
    if hasExtender body then head' (mapMaybe try (zip [0 .. length params] params)) else Nothing
  where
    -- Cheap pre-check: most functions build no extender partial at all.
    hasExtender : RCExp -> Bool
    hasExtender (RLet _ _ _ value rest) = hasExtender value || hasExtender rest
    hasExtender (RUnderApp _ l _ _) = isJust (lookup l exts)
    hasExtender (RCmpCase _ _ _ _ t e) = hasExtender t || hasExtender e
    hasExtender (RConCase _ _ alts mDef) = any (\(MkRConAlt _ _ _ _ b) => hasExtender b) alts || maybe False hasExtender mDef
    hasExtender (RConstCase _ _ alts mDef) = any (\(MkRConstAlt _ b) => hasExtender b) alts || maybe False hasExtender mDef
    hasExtender _ = False

  where
    try : (Nat, (Int, Rep)) -> Maybe (Nat, Int, Nat, SortedMap Int (Name, List RCLocal))
    try (j, (c, RBoxed)) = do
        sites <- contextSites f j c exts body
        guard (not (null sites))
        let holes = nub (mapMaybe (\(l, _) => map hole (lookup l exts)) (values sites))
            cons = nub (mapMaybe (\(l, _) => map (\e => let (_, n, _, _) = e.con in n) (lookup l exts)) (values sites))
        case (holes, cons) of
             ([k], [_]) => pure (j, c, k, sites)
             _ => Nothing
    try _ = Nothing

||| Every function with a context parameter becomes an entry plus its
||| accumulating twin `MN "rc2_ctx_<f>"`; everything else is left as is.
export
applyClosureCtx : {auto v : Ref VarId Int} -> List (Name, RCDef) -> Core (List (Name, RCDef))
applyClosureCtx defs = do
    _ <- newRef FreshId 0
    -- Bound here, not in `where`: a `where` binding is re-evaluated at
    -- every use (doc/constant-constructor-specialization.md).
    newtypes <- pure $ the (SortedSet Name) $ fromList (mapMaybe (\(n, d) => case d of
                                                                       MkRCCon _ _ (Just _) => Just n
                                                                       _ => Nothing) defs)
    exts <- pure $ the (SortedMap Name Extender) $ fromList (mapMaybe (\(n, d) => map (n,) (extenderOf newtypes d)) defs)
    existing <- pure $ the (SortedSet Name) $ fromList (map fst defs)
    if null exts then pure defs else foldr (++) [] <$> traverse (one exts existing) defs
  where
    fresh : {auto r : Ref FreshId Int} -> SortedSet Name -> Name -> Core Name
    fresh existing n = do
        i <- freshId
        let cand = MN ("rc2_ctx_" ++ cName n) i
        if contains cand existing then fresh existing n else pure cand

    one : {auto r : Ref FreshId Int} -> SortedMap Name Extender -> SortedSet Name -> (Name, RCDef) -> Core (List (Name, RCDef))
    one exts existing (n, d@(MkRCFun params@(_ :: _) RBoxed False body)) =
        case contextParam n params exts body of
             Nothing => pure [(n, d)]
             Just (j, c, k, sites) => do
                 n' <- fresh existing n
                 res <- freshVarId
                 last <- freshVarId
                 entry <- rewriteBody n n' j c k exts sites Entry body
                 acc <- rewriteBody n n' j c k exts sites (Acc res last) body
                 pure [ (n, MkRCFun params RBoxed False entry)
                      , (n', MkRCFun (params ++ [(res, RBoxed), (last, RBoxed)]) RBoxed False acc) ]
    one _ _ nd = pure [nd]
