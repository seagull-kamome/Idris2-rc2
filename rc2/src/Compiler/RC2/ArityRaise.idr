||| World arity raising: a function that returns a closure waiting for
||| one more argument (the world, for an `IO`/`Core` function whose
||| lambda the elaborator put inside each branch) gets a version taking
||| that argument itself, and a call whose closure is applied at once
||| calls that version instead. Design, measurements and the reasoning
||| behind each restriction: `rc2/doc/world-arity-raising.md`. Disable
||| with `--directive noarityraise`.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Compiler.RC2.ArityRaise

import Compiler.RC2.Emit.Util
import Compiler.RC2.RCExp
import Compiler.RC2.Util

import Core.Context.Log

import Data.List1
import Data.SortedMap
import Data.SortedSet

%default covering

||| How one tail of a body ends, as far as raising goes.
data ClosureTail = TPartial Name (List RCLocal) | TCall Name | TCrash | TOther

||| The local `w` (the last parameter of a function) is used by `value`, the
||| value of a `let` in front of a tail, in a way that can act on the world:
||| handed to an application, a named call or an external primitive, or copied
||| to another local. A function whose prefix does that has already taken the
||| world as a parameter and acts on it, so the closure it ends in is its
||| *result*, not the world lambda split off; raising it would move that action
||| into the closure (`rc2/doc/world-arity-raising.md`, "Soundness"). The IR has
||| no types to say so: a function that returns an action waiting for the
||| world does not act on its last parameter in the prefix. Left alone,
||| because functions that are rightly raised do it all the time: a `case` on
||| it, a constructor, an arithmetic operation, a partial application that takes
||| it (so a world held in a closure that the prefix then applies is not seen).
worldInPrefix : Int -> RCExp -> Bool
worldInPrefix w e = direct e || any (worldInPrefix w) (children e)
  where
    direct : RCExp -> Bool
    direct (RApp _ _ f args) = f == RCLoc w || elem (RCLoc w) (forget args)
    direct (RAppName _ _ _ args) = elem (RCLoc w) args
    direct (RExtPrim _ _ _ args _) = elem (RCLoc w) args
    direct (RV _ v) = v == RCLoc w
    direct _ = False

||| Every tail of a pre-RC body, through `let` bodies and every branch,
||| and whether the last parameter (`w`) is used by a `let` value on the path
||| to that tail (`worldInPrefix`).
closureTailsWithPrefixCheck : Int -> RCExp -> List (ClosureTail, Bool)
closureTailsWithPrefixCheck w (RLet _ _ _ value body) =
    let worldInValue = worldInPrefix w value
        tails = closureTailsWithPrefixCheck w body
    in map (\(t, inPrefix) => (t, inPrefix || worldInValue)) tails
closureTailsWithPrefixCheck w (RCmpCase _ _ _ _ t f) = closureTailsWithPrefixCheck w t ++ closureTailsWithPrefixCheck w f
closureTailsWithPrefixCheck w (RConCase _ _ alts mDef) =
    foldr (\(MkRConAlt _ _ _ _ b), acc => closureTailsWithPrefixCheck w b ++ acc) (maybe [] (closureTailsWithPrefixCheck w) mDef) alts
closureTailsWithPrefixCheck w (RConstCase _ _ alts mDef) =
    foldr (\(MkRConstAlt _ b), acc => closureTailsWithPrefixCheck w b ++ acc) (maybe [] (closureTailsWithPrefixCheck w) mDef) alts
closureTailsWithPrefixCheck _ (RUnderApp _ g 1 xs) = [(TPartial g xs, False)]
closureTailsWithPrefixCheck _ (RV _ (RCConstClosure g 1)) = [(TPartial g [], False)]
closureTailsWithPrefixCheck _ (RAppName _ Nothing h _) = [(TCall h, False)]
closureTailsWithPrefixCheck _ (RCrash _ _) = [(TCrash, False)]
closureTailsWithPrefixCheck _ _ = [(TOther, False)]

||| The functions to raise: every tail a closure missing exactly one
||| argument of a function taking exactly that many, a crash, or a tail
||| call to another such function (a greatest fixpoint), reaching at
||| least one closure. A CAF (no arguments) is left alone.
raisePlan : List (Name, RCDef) -> SortedSet Name
raisePlan defs =
    let arities : SortedMap Name Nat := fromList (mapMaybe arityOf defs)
        tbl : SortedMap Name (List ClosureTail) := fromList (mapMaybe (tailsOf arities) defs)
    in raiseFixpoint calleeOf isPartial tbl
  where
    arityOf : (Name, RCDef) -> Maybe (Name, Nat)
    arityOf (n, MkRCFun args _ _ _) = Just (n, length args)
    arityOf _ = Nothing

    ||| `Nothing` for a CAF or for a function with a tail that can never
    ||| be raised; a closure of a function of another arity counts as one.
    ||| Also `Nothing` if the last parameter (the world) is mentioned in
    ||| any let value on the path to a tail: raising would move effects
    ||| from the prefix into the closure body.
    tailsOf : SortedMap Name Nat -> (Name, RCDef) -> Maybe (Name, List ClosureTail)
    tailsOf ar (n, MkRCFun args@(_ :: _) _ False body) =
        let w = fst (last args)
            tails = closureTailsWithPrefixCheck w body
        in if all (\(t, used) => not used && ok ar t) tails
           then Just (n, map fst tails) else Nothing
      where
        ok : SortedMap Name Nat -> ClosureTail -> Bool
        ok ar (TPartial g xs) = lookup g ar == Just (S (length xs))
        ok _ TOther = False
        ok _ _ = True
    tailsOf _ _ = Nothing

    isPartial : ClosureTail -> Bool
    isPartial (TPartial _ _) = True
    isPartial _ = False

    calleeOf : ClosureTail -> Maybe Name
    calleeOf (TCall h) = Just h
    calleeOf _ = Nothing

||| `f`'s body is exactly `partial g missing= 1 [its parameters]`: its
||| callers can call `g` directly, no raised version needed.
bareWrapperOf : List (Int, Rep) -> RCExp -> Maybe Name
bareWrapperOf args (RUnderApp _ g 1 xs) = if xs == map (RCLoc . fst) args then Just g else Nothing
bareWrapperOf _ _ = Nothing

||| `body`'s tails handed the extra argument `w`: a closure becomes the
||| saturated call, a tail call to a raised function calls what it was
||| raised to (`targets`), a crash stays.
raiseTails : SortedMap Name Name -> Int -> RCExp -> RCExp
raiseTails ts w (RLet fc x rep value body) = RLet fc x rep value (raiseTails ts w body)
raiseTails ts w (RCmpCase fc op args pd t f) = RCmpCase fc op args pd (raiseTails ts w t) (raiseTails ts w f)
raiseTails ts w (RConCase fc sc alts mDef) =
    RConCase fc sc (map (\(MkRConAlt n ci tag as b) => MkRConAlt n ci tag as (raiseTails ts w b)) alts)
      (map (raiseTails ts w) mDef)
raiseTails ts w (RConstCase fc sc alts mDef) =
    RConstCase fc sc (map (\(MkRConstAlt c b) => MkRConstAlt c (raiseTails ts w b)) alts)
      (map (raiseTails ts w) mDef)
raiseTails _ w (RUnderApp fc g 1 xs) = RAppName fc Nothing g (xs ++ [RCLoc w])
raiseTails _ w (RV fc (RCConstClosure g 1)) = RAppName fc Nothing g [RCLoc w]
raiseTails ts w e@(RAppName fc Nothing h ys) = case lookup h ts of
    Just t => RAppName fc Nothing t (ys ++ [RCLoc w])
    Nothing => e
raiseTails _ _ e = e

||| Every `let c = call f xs` whose `c` is used only by an `apply c [w]`
||| evaluated right after it -- the `let`'s own body, or the value of the
||| `let` that body starts with -- becomes a call to what `f` was raised
||| to. The call may sit at the end of a chain of `let`s in the value;
||| the raised call takes its place there.
rewriteSites : SortedMap Name Name -> RCExp -> RCExp
rewriteSites ts e = here (mapChildren (rewriteSites ts) e)
  where
    ||| The call `value` ends in, through the `let`s in front of it, and
    ||| `value` with that call replaced.
    finalCall : RCExp -> Maybe (FC, Name, List RCLocal, RCExp -> RCExp)
    finalCall (RLet fc x rep v b) = map (\(cfc, f, xs, k) => (cfc, f, xs, RLet fc x rep v . k)) (finalCall b)
    finalCall (RAppName fc Nothing f xs) = Just (fc, f, xs, id)
    finalCall _ = Nothing

    raisedCall : Int -> RCExp -> RCExp -> Maybe RCExp
    raisedCall c value (RApp _ Nothing (RCLoc c') (w ::: [])) =
        if c' /= c || w == RCLoc c then Nothing
        else do
            (fc, f, xs, k) <- finalCall value
            t <- lookup f ts
            pure (k (RAppName fc Nothing t (xs ++ [w])))
    raisedCall _ _ _ = Nothing

    here : RCExp -> RCExp
    here e@(RLet _ c _ value body) =
        case raisedCall c value body of
             Just call => call
             Nothing => case body of
                 RLet fc' x rep v2 rest =>
                     case raisedCall c value v2 of
                          Just call => if countUsesR (RCLoc c) rest == 0 then RLet fc' x rep call rest else e
                          Nothing => e
                 _ => e
    here e = e

||| The raise itself: each planned function `f` (not a bare wrapper) gets
||| `f#` (`rc2_raised_<f>`) with one more parameter, and becomes a bare
||| wrapper of it; every body's call sites are rewritten.
export
applyArityRaise : {auto c : Ref Ctxt Defs} -> {auto v : Ref VarId Int} -> List (Name, RCDef) -> Core (List (Name, RCDef))
applyArityRaise defs = do
    _ <- newRef FreshId 0
    plan <- logTime 3 "rc2: Arity raise (plan)" $ pure (raisePlan defs)
    let
        existing : SortedSet Name := fromList (map fst defs)
    named <- logTime 3 "rc2: Arity raise (names)" $ traverse (nameOf plan existing) defs
    let targets : SortedMap Name Name := fromList (mapMaybe (\(n, _, t) => map (\t' => (n, t')) t) named)
    -- `foldr (++)`, not `concat`: that is `foldMap`, a left fold of `++`,
    -- quadratic over the whole program.
    logTime 3 "rc2: Arity raise (rewrite)" $ foldr (++) [] <$> traverse (raise targets) named
  where
    nameOf : {auto r : Ref FreshId Int} -> SortedSet Name -> SortedSet Name -> (Name, RCDef)
           -> Core (Name, RCDef, Maybe Name)
    nameOf plan existing (n, d@(MkRCFun args _ _ body)) =
        if not (contains n plan) then pure (n, d, Nothing)
        else case bareWrapperOf args body of
                  Just g => pure (n, d, Just g)
                  Nothing => (\r => (n, d, Just r)) <$> fresh existing n
      where
        fresh : SortedSet Name -> Name -> Core Name
        fresh existing n = do
            i <- freshId
            let cand = MN ("rc2_raised_" ++ cName n) i
            if contains cand existing then fresh existing n else pure cand
    nameOf _ _ (n, d) = pure (n, d, Nothing)

    raise : SortedMap Name Name -> (Name, RCDef, Maybe Name) -> Core (List (Name, RCDef))
    raise ts (n, MkRCFun args retRep isWorker body, Just r) =
        case bareWrapperOf args body of
             Just _ => pure [(n, MkRCFun args retRep isWorker (rewriteSites ts body))]
             Nothing => do
                 w <- freshVarId
                 let raised = raiseTails ts w (rewriteSites ts body)
                     wrapper = RUnderApp emptyFC r 1 (map (RCLoc . fst) args)
                 pure [ (n, MkRCFun args retRep isWorker wrapper)
                      , (r, MkRCFun (args ++ [(w, RBoxed)]) retRep isWorker raised) ]
    raise ts (n, MkRCFun args retRep isWorker body, Nothing) =
        pure [(n, MkRCFun args retRep isWorker (rewriteSites ts body))]
    raise ts (n, MkRCError body, _) = pure [(n, MkRCError (rewriteSites ts body))]
    raise _ (n, d, _) = pure [(n, d)]

------------------------------------------------------------------------
-- After `LateInline`: folding a closure applied at once (post-RC).
-- doc/world-arity-raising.md's "Post-RC fold".

||| Every mention of `l` in `e`, release positions included.
mentions : RCLocal -> RCExp -> Nat
mentions l e = length (filter (== l) (directReads e ++ releases e)) + sum (map (mentions l) (children e))
  where
    releases : RCExp -> List RCLocal
    releases (RDrop _ vs _) = vs
    releases (RReuseOffer _ sc _ _ _) = [sc]
    releases (RReleaseReuse _ x _) = [x]
    releases (RCon _ _ _ _ _ reuseFrom) = toList reuseFrom
    releases _ = []

||| The locals of a body that carry no reference count: bound with a
||| native Rep, as a parameter or `let` or loop parameter. The second
||| set holds the `RInlineNative` ones, spliced where they are read, so
||| their read must not move.
nativeLocals : List (Int, Rep) -> RCExp -> (SortedSet Int, SortedSet Int)
nativeLocals args body =
    let (ns, inl) = go body
    in (union ns (fromList (mapMaybe (\(i, r) => if isNativeRep r then Just i else Nothing) args)), inl)
  where
    both : List (SortedSet Int, SortedSet Int) -> (SortedSet Int, SortedSet Int)
    both = foldl (\(a, b), (c, d) => (union a c, union b d)) (empty, empty)

    go : RCExp -> (SortedSet Int, SortedSet Int)
    go e@(RLet _ x rep _ _) =
        let (ns, inl) = both (map go (children e))
        in case rep of
                RInlineNative _ => (insert x ns, insert x inl)
                RBoxed => (ns, inl)
                _ => (insert x ns, inl)
    go e@(RLoop _ ps _ _ _) =
        let (ns, inl) = both (map go (children e))
        in (union ns (fromList (mapMaybe (\(i, r) => if isNativeRep r then Just i else Nothing) ps)), inl)
    go e = both (map go (children e))

||| Each bare wrapper `f params = partial g m params` (m > 0), as `(g, m)`.
bareWrappers : List (Name, RCDef) -> SortedMap Name (Name, Nat)
bareWrappers defs = fromList (mapMaybe wrapperOf defs)
  where
    wrapperOf : (Name, RCDef) -> Maybe (Name, (Name, Nat))
    wrapperOf (n, MkRCFun args _ _ (RUnderApp _ g m xs)) =
        if m > 0 && xs == map (RCLoc . fst) args then Just (n, (g, m)) else Nothing
    wrapperOf _ = Nothing

||| A value that ends, through leading `let`s and `dup`s, in a closure
||| (a `partial`, or a call to a bare wrapper): those leading nodes as a
||| function of what follows them, and the closure's target, missing
||| count and captured arguments.
closureValue : SortedMap Name (Name, Nat) -> RCExp -> Maybe (RCExp -> RCExp, Name, Nat, List RCLocal)
closureValue ws (RLet fc x rep v b) = map (\(k, g, m, xs) => (RLet fc x rep v . k, g, m, xs)) (closureValue ws b)
closureValue ws (RDup fc x n b) = map (\(k, g, m, xs) => (RDup fc x n . k, g, m, xs)) (closureValue ws b)
closureValue _ (RUnderApp _ g m xs) = if m > 0 then Just (id, g, m, xs) else Nothing
closureValue ws (RAppName _ Nothing f xs) = map (\(g, m) => (id, g, m, xs)) (lookup f ws)
closureValue _ _ = Nothing

||| How often `c` is named in a `drop` in `e`.
dropMentions : RCLocal -> RCExp -> Nat
dropMentions c (RDrop _ vs k) = length (filter (== c) vs) + dropMentions c k
dropMentions c e = sum (map (dropMentions c) (children e))

||| `e` with its one `apply c ys` built by `mk` instead, and each
||| `drop` of `c` dropping `owned` (what the closure held) instead;
||| `Nothing` when `c` sits inside a loop, or `mk` declines.
replaceApply : Int -> List RCLocal -> (FC -> List RCLocal -> Maybe RCExp) -> RCExp -> Maybe RCExp
replaceApply c _ mk e@(RApp fc Nothing (RCLoc c') ys) = if c' == c then mk fc (forget ys) else Just e
replaceApply c owned mk (RDrop fc vs k) =
    let vs' = concatMap (\v => if v == RCLoc c then owned else [v]) vs
    in (\k' => if null vs' then k' else RDrop fc vs' k') <$> replaceApply c owned mk k
replaceApply c _ _ e@(RLoop _ _ _ _ _) = if mentions (RCLoc c) e > 0 then Nothing else Just e
replaceApply c owned mk e = if mentions (RCLoc c) e == 0 then Just e else traverseChildren (replaceApply c owned mk) e

||| Every `let c = <closure>` whose `c` is then applied once, supplying
||| exactly what it misses (or one more, to a bare wrapper missing one),
||| and otherwise only dropped, becomes a call at that `apply`; each drop
||| of it drops the closure's captured Boxed arguments instead.
foldAppliedExp : SortedMap Name (Name, Nat) -> (SortedSet Int, SortedSet Int) -> RCExp -> RCExp
foldAppliedExp ws nat e = here (mapChildren (foldAppliedExp ws nat) e)
  where
    target : Name -> Nat -> List RCLocal -> FC -> List RCLocal -> Maybe RCExp
    target g m xs fc ys =
        if length ys == m then Just (RAppName fc Nothing g (xs ++ ys))
        else if length ys == S m
                then case lookup g ws of
                          Just (h, 1) => Just (RAppName fc Nothing h (xs ++ ys))
                          _ => Nothing
                else Nothing

    isLoc : (Int -> Bool) -> RCLocal -> Bool
    isLoc p (RCLoc i) = p i
    isLoc _ _ = False

    here : RCExp -> RCExp
    here e@(RLet _ c RBoxed value body) = fromMaybe e $ do
        (lead, g, m, xs) <- closureValue ws value
        let owned = filter (isLoc (\i => not (contains i (fst nat)))) xs
            n = mentions (RCLoc c) body
        guard (not (any (isLoc (\i => contains i (snd nat))) xs || n /= S (dropMentions (RCLoc c) body)))
        body' <- replaceApply c owned (target g m xs) body
        guard (mentions (RCLoc c) body' == 0)
        pure (lead body')
    here e = e

||| The post-RC fold over every definition.
export
applyFoldApplied : List (Name, RCDef) -> List (Name, RCDef)
applyFoldApplied defs =
    let ws = bareWrappers defs
    in map (\(n, d) => (n, foldDef ws d)) defs
  where
    foldDef : SortedMap Name (Name, Nat) -> RCDef -> RCDef
    foldDef ws (MkRCFun args retRep isWorker body) = MkRCFun args retRep isWorker (foldAppliedExp ws (nativeLocals args body) body)
    foldDef ws (MkRCError body) = MkRCError (foldAppliedExp ws (nativeLocals [] body) body)
    foldDef _ d = d
