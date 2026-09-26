||| World arity raising: a function that returns a closure waiting for
||| one more argument (the world, for an `IO`/`Core` function whose
||| lambda the elaborator put inside each branch) gets a version taking
||| that argument itself, and a call whose closure is applied at once
||| calls that version instead. Design, measurements and the reasoning
||| behind each restriction: `rc2/doc/world-arity-raising.md`. Disable
||| with `--directive noarityraise`.
module Compiler.RC2.ArityRaise

import Compiler.RC2.Emit.Util
import Compiler.RC2.RCExp
import Compiler.RC2.Util

import Core.Core
import Core.FC
import Core.Context

import Data.List
import Data.SortedMap
import Data.SortedSet

%default covering

||| How one tail of a body ends, as far as raising goes.
data ClosureTail = TPartial Name (List RCLocal) | TCall Name | TCrash | TOther

||| Every tail of a pre-RC body, through `let` bodies and every branch.
closureTails : RCExp -> List ClosureTail
closureTails (RLet _ _ _ _ body) = closureTails body
closureTails (RCmpCase _ _ _ _ t f) = closureTails t ++ closureTails f
closureTails (RConCase _ _ alts mDef) =
    foldr (\(MkRConAlt _ _ _ _ b), acc => closureTails b ++ acc) (maybe [] closureTails mDef) alts
closureTails (RConstCase _ _ alts mDef) =
    foldr (\(MkRConstAlt _ b), acc => closureTails b ++ acc) (maybe [] closureTails mDef) alts
closureTails (RUnderApp _ g 1 xs) = [TPartial g xs]
closureTails (RV _ (RCConstClosure g 1)) = [TPartial g []]
closureTails (RAppName _ Nothing h _) = [TCall h]
closureTails (RCrash _ _) = [TCrash]
closureTails _ = [TOther]

||| The functions to raise: every tail a closure missing exactly one
||| argument of a function taking exactly that many, a crash, or a tail
||| call to another such function (a greatest fixpoint), reaching at
||| least one closure. A CAF (no arguments) is left alone.
raisePlan : List (Name, RCDef) -> SortedSet Name
raisePlan defs =
    let arities : SortedMap Name Nat := fromList (mapMaybe arityOf defs)
        tbl : SortedMap Name (List ClosureTail) := fromList (mapMaybe (tailsOf arities) defs)
        closed = shrink tbl (fromList (keys tbl))
    in reach tbl closed (fromList (filter (\n => any isPartial (fromMaybe [] (lookup n tbl))) (SortedSet.toList closed)))
  where
    arityOf : (Name, RCDef) -> Maybe (Name, Nat)
    arityOf (n, MkRCFun args _ _ _) = Just (n, length args)
    arityOf _ = Nothing

    ||| `Nothing` for a CAF or for a function with a tail that can never
    ||| be raised; a closure of a function of another arity counts as one.
    tailsOf : SortedMap Name Nat -> (Name, RCDef) -> Maybe (Name, List ClosureTail)
    tailsOf ar (n, MkRCFun args@(_ :: _) _ False body) =
        let ts = closureTails body
        in if all (ok ar) ts then Just (n, ts) else Nothing
      where
        ok : SortedMap Name Nat -> ClosureTail -> Bool
        ok ar (TPartial g xs) = lookup g ar == Just (S (length xs))
        ok _ TOther = False
        ok _ _ = True
    tailsOf _ _ = Nothing

    isPartial : ClosureTail -> Bool
    isPartial (TPartial _ _) = True
    isPartial _ = False

    callsIn : SortedSet Name -> ClosureTail -> Bool
    callsIn s (TCall h) = contains h s
    callsIn _ _ = False

    okIn : SortedSet Name -> ClosureTail -> Bool
    okIn s (TCall h) = contains h s
    okIn _ _ = True

    shrink : SortedMap Name (List ClosureTail) -> SortedSet Name -> SortedSet Name
    shrink tbl s =
        let s' = fromList (filter (\n => all (okIn s) (fromMaybe [] (lookup n tbl))) (SortedSet.toList s))
        in if length (SortedSet.toList s') == length (SortedSet.toList s) then s' else shrink tbl s'

    reach : SortedMap Name (List ClosureTail) -> SortedSet Name -> SortedSet Name -> SortedSet Name
    reach tbl closed ps =
        let ps' = fromList (filter (\n => contains n ps || any (callsIn ps) (fromMaybe [] (lookup n tbl)))
                                   (SortedSet.toList closed))
        in if length (SortedSet.toList ps') == length (SortedSet.toList ps) then ps' else reach tbl closed ps'

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
    raisedCall c value (RApp _ Nothing (RCLoc c') [w]) =
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
applyArityRaise : {auto v : Ref VarId Int} -> List (Name, RCDef) -> Core (List (Name, RCDef))
applyArityRaise defs = do
    _ <- newRef FreshId 0
    let plan = raisePlan defs
        existing : SortedSet Name := fromList (map fst defs)
    named <- traverse (nameOf plan existing) defs
    let targets : SortedMap Name Name := fromList (mapMaybe (\(n, _, t) => map (\t' => (n, t')) t) named)
    concat <$> traverse (raise targets) named
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
    in (union ns (fromList (mapMaybe (\(i, r) => if isBoxed r then Nothing else Just i) args)), inl)
  where
    isBoxed : Rep -> Bool
    isBoxed RBoxed = True
    isBoxed _ = False

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
        in (union ns (fromList (mapMaybe (\(i, r) => if isBoxed r then Nothing else Just i) ps)), inl)
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
replaceApply c _ mk e@(RApp fc Nothing (RCLoc c') ys) = if c' == c then mk fc ys else Just e
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
        the (Maybe ()) (if any (isLoc (\i => contains i (snd nat))) xs || n /= S (dropMentions (RCLoc c) body)
                           then Nothing else Just ())
        body' <- replaceApply c owned (target g m xs) body
        the (Maybe ()) (if mentions (RCLoc c) body' == 0 then Just () else Nothing)
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
