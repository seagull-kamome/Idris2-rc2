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
