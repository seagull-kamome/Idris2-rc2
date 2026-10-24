module Compiler.RC2.FunDedup

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Merges functions whose bodies are the same up to the numbering of
-- their local variables (a structural comparison, never printed text), the last whole-program step of `toRCDefs`
-- (rc2/doc/fun-dedup.md). Cloning and lifting leave many such
-- functions: closures lifted from identical lambdas, specialisation
-- clones that ended up the same, DualABI workers of equal wrappers.

import Compiler.RC2.DeadCode
import Compiler.RC2.Pretty
import Compiler.RC2.RCExp

import Core.CompileExpr
import Core.TT

import Data.DPair
import Data.List1
import Data.SortedMap
import Data.SortedSet
import Data.String
import Data.Vect

%default covering

------------------------------------------------------------------------
-- Renaming the functions a body refers to
------------------------------------------------------------------------

renameLocalN : (Name -> Name) -> RCLocal -> RCLocal
renameLocalN f (RCConstClosure n missing) = RCConstClosure (f n) missing
renameLocalN _ l = l

mutual
  ||| `e` with every function name `f` maps changed. A `RCConstCon`'s
  ||| fields are left as they are (its erased proof cannot be rebuilt):
  ||| a closure constant inside one keeps its function alive, which is
  ||| safe, only less thorough.
  renameNamesR : (Name -> Name) -> RCExp -> RCExp
  renameNamesR f = go
    where
      l : RCLocal -> RCLocal
      l = renameLocalN f

      ls : List RCLocal -> List RCLocal
      ls = map l

      go : RCExp -> RCExp
      go (RV fc v) = RV fc (l v)
      go (RAppName fc lazy n args) = RAppName fc lazy (f n) (ls args)
      go (RAppNameRep fc n argReps retRep postDrop args) = RAppNameRep fc (f n) argReps retRep (ls postDrop) (ls args)
      go (RAppFFIInline fc ccs fargs ret postDrop args) = RAppFFIInline fc ccs fargs ret (ls postDrop) (ls args)
      go (RUnderApp fc n missing args) = RUnderApp fc (f n) missing (ls args)
      go (RDelay fc lr n caps) = RDelay fc lr (f n) (ls caps)
      go (RForce fc lr v postDrop) = RForce fc lr (l v) (ls postDrop)
      go (RApp fc lazy c args) = RApp fc lazy (l c) (map l args)
      go (RLet fc var rep value body) = RLet fc var rep (go value) (go body)
      go (RCon fc n ci tag args reuseFrom) = RCon fc n ci tag (ls args) (map l reuseFrom)
      go (RRetPack fc n tag fields) = RRetPack fc n tag (ls fields)
      go (ROp fc lazy op args postDrop) = ROp fc lazy op (map l args) (ls postDrop)
      go (RExtPrim fc lazy p args postDrop) = RExtPrim fc lazy p (ls args) (ls postDrop)
      go (RStructGet fc sv sf postDrop) = RStructGet fc (l sv) sf (ls postDrop)
      go (RStructSet fc sv sf value postDrop) = RStructSet fc (l sv) sf (l value) (ls postDrop)
      go (RFill fc cell k value postDrop) = RFill fc (l cell) k (l value) (ls postDrop)
      go (RCmpCase fc op args postDrop t e) = RCmpCase fc op (map l args) (ls postDrop) (go t) (go e)
      go (RConCase fc sc alts mDef) =
          RConCase fc (l sc) (map (\(MkRConAlt n ci tag as body) => MkRConAlt n ci tag as (go body)) alts) (map go mDef)
      go (RConstCase fc sc alts mDef) =
          RConstCase fc (l sc) (map (\(MkRConstAlt c body) => MkRConstAlt c (go body)) alts) (map go mDef)
      go (RPrimVal fc c) = RPrimVal fc c
      go (RErased fc) = RErased fc
      go (RCrash fc msg) = RCrash fc msg
      go (RDup fc v extra body) = RDup fc (l v) extra (go body)
      go (RDrop fc vars body) = RDrop fc (ls vars) (go body)
      go (RFree fc v body) = RFree fc (l v) (go body)
      go (RReleaseReuse fc v body) = RReleaseReuse fc (l v) (go body)
      go (RReuseOffer fc sc dupOnShared dropOnUnique body) =
          RReuseOffer fc (l sc) (ls dupOnShared) (ls dropOnUnique) (go body)
      go (RLoop fc params initial prologueDrop body) = RLoop fc params (ls initial) (ls prologueDrop) (go body)
      go (RLoopContinue fc args postDrop) = RLoopContinue fc (ls args) (ls postDrop)
      go (RMemoize fc n rep body) = RMemoize fc n rep (go body)

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------

isFatConst : RCLocal -> Bool
isFatConst (RCConstCon _ _ _ (_ :: _)) = True
isFatConst _ = False

||| `True` iff `e` holds a constant constructor with fields (a tree shared in
||| memory, whose unfolded size can be huge, so comparing it is no cheap
||| matter) or an inlined FFI call (not compared structurally). Such a
||| function is no candidate.
hasFatConst : RCExp -> Bool
hasFatConst = go
  where
    l : RCLocal -> Bool
    l = isFatConst

    ls : List RCLocal -> Bool
    ls = any l

    go : RCExp -> Bool
    go (RV _ v) = l v
    go (RAppName _ _ _ args) = ls args
    go (RAppNameRep _ _ _ _ postDrop args) = ls postDrop || ls args
    go (RAppFFIInline {}) = True
    go (RUnderApp _ _ _ args) = ls args
    go (RDelay _ _ _ caps) = ls caps
    go (RForce _ _ v postDrop) = l v || ls postDrop
    go (RApp _ _ c args) = l c || any l args
    go (RLet _ _ _ value body) = go value || go body
    go (RCon _ _ _ _ args reuseFrom) = ls args || maybe False l reuseFrom
    go (RRetPack _ _ _ fields) = ls fields
    go (ROp _ _ _ args postDrop) = any l args || ls postDrop
    go (RExtPrim _ _ _ args postDrop) = ls args || ls postDrop
    go (RStructGet _ sv _ postDrop) = l sv || ls postDrop
    go (RStructSet _ sv _ value postDrop) = l sv || l value || ls postDrop
    go (RFill _ cell _ value postDrop) = l cell || l value || ls postDrop
    go (RCmpCase _ _ args postDrop t e) = any l args || ls postDrop || go t || go e
    go (RConCase _ sc alts mDef) =
        l sc || any (\(MkRConAlt _ _ _ _ body) => go body) alts || maybe False go mDef
    go (RConstCase _ sc alts mDef) =
        l sc || any (\(MkRConstAlt _ body) => go body) alts || maybe False go mDef
    go (RPrimVal _ _) = False
    go (RErased _) = False
    go (RCrash _ _) = False
    go (RDup _ v _ body) = l v || go body
    go (RDrop _ vars body) = ls vars || go body
    go (RFree _ v body) = l v || go body
    go (RReleaseReuse _ v body) = l v || go body
    go (RReuseOffer _ sc dupOnShared dropOnUnique body) = l sc || ls dupOnShared || ls dropOnUnique || go body
    go (RLoop _ _ initial prologueDrop body) = ls initial || ls prologueDrop || go body
    go (RLoopContinue _ args postDrop) = ls args || ls postDrop
    go (RMemoize _ _ _ body) = go body

renameNamesD : (Name -> Name) -> RCDef -> RCDef
renameNamesD f (MkRCFun args r w body) = MkRCFun args r w (renameNamesR f body)
renameNamesD f (MkRCError body) = MkRCError (renameNamesR f body)
renameNamesD _ d = d

------------------------------------------------------------------------
-- Candidates
------------------------------------------------------------------------

||| The functions a definition refers to (not constructors: a constant
||| constructor can unfold to a huge tree). A set, so that the walk of a
||| shared constant costs time but no memory.
refNames : RCDef -> SortedSet Name
refNames =
    foldRCNamesD {m = SortedSet Name} $ { onAppName      := \n, _ => singleton n
                                        , onAppNameRep   := singleton
                                        , onUnderApp     := singleton
                                        , onConstClosure := singleton
                                        } (noRCNames {m = SortedSet Name})

||| The number of nodes of `e`.
nodeSize : RCExp -> Nat
nodeSize e = S (sum (map nodeSize (children e)))

isCandidate : RCDef -> Bool
isCandidate (MkRCFun (_ :: _) _ _ body) = not (hasFatConst body)
isCandidate _ = False

||| The name a function's own references to itself are renamed to before
||| keying, so that two self-recursive twins agree.
selfName : Name
selfName = UN (Basic "@self")

ShallowKey : Type
ShallowKey = (Nat, Nat, Int, String, List Name)

noKey : ShallowKey
noKey = (0, 0, 0, "", [])

||| A hash of the constants and constructors in `e`, in walk order (equal
||| bodies walk alike), so that functions differing only in a constant
||| land in different buckets.
leafHash : RCExp -> Int
leafHash e = go 7 [e]
  where
    mix : Int -> String -> Int
    mix h s = foldl (\a, ch => (a * 31 + ord ch) `mod` 1000000007) h (unpack s)

    leaf : Int -> RCExp -> Int
    leaf a (RPrimVal _ c) = mix a (show c)
    leaf a (RCon _ n _ t _ _) = mix (mix a (show n)) (show t)
    leaf a (RConstCase _ _ alts _) = foldl (\b, (MkRConstAlt c _) => mix b (show c)) a alts
    leaf a _ = a

    -- A work list instead of recursion: the walk is over the whole body.
    go : Int -> List RCExp -> Int
    go h [] = h
    go h (x :: xs) = go (leaf h x) (children x ++ xs)

||| The first-level key: what is cheap to compute and does not depend on
||| the numbering of locals. Equal keys are only a candidate for equal
||| functions.
shallowKey : Name -> RCDef -> SortedSet Name -> Nat -> ShallowKey
shallowKey name def refSet size =
    case def of
         MkRCFun args r w body =>
             let refs = map (\m => if m == name then selfName else m) (Prelude.toList refSet)
                 sig = joinBy "," (map (\(_, rp) => prettyRep rp) args) ++ " -> " ++ prettyRep r ++ (if w then " worker" else "")
             in (length args, size, leafHash body, sig, Prelude.toList (SortedSet.fromList refs))
         _ => (0, size, 0, "", [])

||| A function with its parameters and its references, kept across rounds so
||| that a round never walks a body it has no reason to touch.
record Cand where
  constructor MkCand
  name : Name
  def : RCDef
  refs : SortedSet Name
  size : Nat
  ||| `isCandidate`, decided once: renaming names changes neither it nor the constants.
  candidate : Bool
  ||| `shallowKey`, computed once with the rest: renaming names rebuilds the `Cand`, nothing else changes it.
  key : ShallowKey

mkCand : Name -> RCDef -> Cand
mkCand n d@(MkRCFun _ _ _ body) =
    let refs = refNames d
        size = nodeSize body
        cand = isCandidate d
    in MkCand n d refs size cand (if cand then shallowKey n d refs size else noKey)
-- Not a function (a constructor, a foreign declaration, an error body): never a candidate, but
-- an error body may call a merged function, so its references still count.
mkCand n d = MkCand n d (refNames d) 0 False noKey

------------------------------------------------------------------------
-- Equality up to the numbering of locals
------------------------------------------------------------------------

||| The pairing of the locals of one function (`fwd`) with those of the
||| other (`bwd`), and the two names that stand for "the function itself".
record Env where
  constructor MkEnv
  fwd : SortedMap Int Int
  bwd : SortedMap Int Int
  selfA : Name
  selfB : Name

bind : Int -> Int -> Env -> Maybe Env
bind a b env =
    case (lookup a env.fwd, lookup b env.bwd) of
         (Nothing, Nothing) => Just ({ fwd $= insert a b, bwd $= insert b a } env)
         (Just b', Just a') => if b' == b && a' == a then Just env else Nothing
         _ => Nothing

bindAll : Env -> List Int -> List Int -> Maybe Env
bindAll env [] [] = Just env
bindAll env (a :: as) (b :: bs) = bind a b env >>= \env' => bindAll env' as bs
bindAll _ _ _ = Nothing

eqName : Env -> Name -> Name -> Bool
eqName env x y =
    (x == env.selfA && y == env.selfB) || (x == y && x /= env.selfA && y /= env.selfB)

eqL : Env -> RCLocal -> RCLocal -> Bool
eqL env (RCLoc a) (RCLoc b) =
    case (lookup a env.fwd, lookup b env.bwd) of
         (Just b', Just a') => a' == a && b' == b
         (Nothing, Nothing) => a == b
         _ => False
eqL env (RCConstClosure n1 m1) (RCConstClosure n2 m2) = m1 == m2 && eqName env n1 n2
eqL _ x y = x == y

eqLs : Env -> List RCLocal -> List RCLocal -> Bool
eqLs env [] [] = True
eqLs env (x :: xs) (y :: ys) = eqL env x y && eqLs env xs ys
eqLs _ _ _ = False

eqMaybeL : Env -> Maybe RCLocal -> Maybe RCLocal -> Bool
eqMaybeL _ Nothing Nothing = True
eqMaybeL env (Just x) (Just y) = eqL env x y
eqMaybeL _ _ _ = False

eqRep : Rep -> Rep -> Bool
eqRep x y = prettyRep x == prettyRep y

eqReps : List Rep -> List Rep -> Bool
eqReps [] [] = True
eqReps (x :: xs) (y :: ys) = eqRep x y && eqReps xs ys
eqReps _ _ = False

eqLazy : Maybe LazyReason -> Maybe LazyReason -> Bool
eqLazy x y = show x == show y

mutual
  ||| `Just` the pairing after the two expressions, if they are equal up to
  ||| the pairing of their locals. Constructors this does not cover (struct
  ||| access, inlined FFI calls, memoization) are never equal to anything.
  eqE : Env -> RCExp -> RCExp -> Maybe Env
  eqE env (RV _ x) (RV _ y) = if eqL env x y then Just env else Nothing
  eqE env (RAppName _ l1 n1 a1) (RAppName _ l2 n2 a2) =
      if eqLazy l1 l2 && eqName env n1 n2 && eqLs env a1 a2 then Just env else Nothing
  eqE env (RAppNameRep _ n1 ar1 rr1 pd1 a1) (RAppNameRep _ n2 ar2 rr2 pd2 a2) =
      if eqName env n1 n2 && eqReps ar1 ar2 && eqRep rr1 rr2 && eqLs env pd1 pd2 && eqLs env a1 a2
         then Just env else Nothing
  eqE env (RUnderApp _ n1 m1 a1) (RUnderApp _ n2 m2 a2) =
      if m1 == m2 && eqName env n1 n2 && eqLs env a1 a2 then Just env else Nothing
  eqE env (RDelay _ lr1 n1 c1) (RDelay _ lr2 n2 c2) =
      if show lr1 == show lr2 && eqName env n1 n2 && eqLs env c1 c2 then Just env else Nothing
  eqE env (RForce _ lr1 v1 pd1) (RForce _ lr2 v2 pd2) =
      if show lr1 == show lr2 && eqL env v1 v2 && eqLs env pd1 pd2 then Just env else Nothing
  eqE env (RApp _ l1 c1 a1) (RApp _ l2 c2 a2) =
      if eqLazy l1 l2 && eqL env c1 c2 && eqLs env (forget a1) (forget a2) then Just env else Nothing
  eqE env (RLet _ v1 r1 val1 b1) (RLet _ v2 r2 val2 b2) =
      if not (eqRep r1 r2) then Nothing
      else eqE env val1 val2 >>= \env1 => bind v1 v2 env1 >>= \env2 => eqE env2 b1 b2
  eqE env (RCon _ n1 ci1 t1 a1 rf1) (RCon _ n2 ci2 t2 a2 rf2) =
      if n1 == n2 && ci1 == ci2 && t1 == t2 && eqLs env a1 a2 && eqMaybeL env rf1 rf2
         then Just env else Nothing
  eqE env (RRetPack _ n1 t1 f1) (RRetPack _ n2 t2 f2) =
      if n1 == n2 && t1 == t2 && eqLs env f1 f2 then Just env else Nothing
  eqE env (ROp _ l1 o1 a1 pd1) (ROp _ l2 o2 a2 pd2) =
      if eqLazy l1 l2 && show o1 == show o2 && eqLs env (toList a1) (toList a2) && eqLs env pd1 pd2
         then Just env else Nothing
  eqE env (RExtPrim _ l1 p1 a1 pd1) (RExtPrim _ l2 p2 a2 pd2) =
      if eqLazy l1 l2 && p1 == p2 && eqLs env a1 a2 && eqLs env pd1 pd2 then Just env else Nothing
  eqE env (RFill _ c1 k1 v1 pd1) (RFill _ c2 k2 v2 pd2) =
      if k1 == k2 && eqL env c1 c2 && eqL env v1 v2 && eqLs env pd1 pd2 then Just env else Nothing
  eqE env (RCmpCase _ o1 a1 pd1 t1 e1) (RCmpCase _ o2 a2 pd2 t2 e2) =
      if show (Subset.fst o1) == show (Subset.fst o2) && eqLs env (toList a1) (toList a2) && eqLs env pd1 pd2
         then eqE env t1 t2 >>= \env1 => eqE env1 e1 e2
         else Nothing
  eqE env (RConCase _ s1 alts1 d1) (RConCase _ s2 alts2 d2) =
      if eqL env s1 s2 then eqAlts env alts1 alts2 >>= \env1 => eqMaybe env1 d1 d2 else Nothing
  eqE env (RConstCase _ s1 alts1 d1) (RConstCase _ s2 alts2 d2) =
      if eqL env s1 s2 then eqCAlts env alts1 alts2 >>= \env1 => eqMaybe env1 d1 d2 else Nothing
  eqE env (RPrimVal _ c1) (RPrimVal _ c2) = if c1 == c2 then Just env else Nothing
  eqE env (RErased _) (RErased _) = Just env
  eqE env (RCrash _ m1) (RCrash _ m2) = if m1 == m2 then Just env else Nothing
  eqE env (RDup _ v1 x1 b1) (RDup _ v2 x2 b2) =
      if x1 == x2 && eqL env v1 v2 then eqE env b1 b2 else Nothing
  eqE env (RDrop _ vs1 b1) (RDrop _ vs2 b2) = if eqLs env vs1 vs2 then eqE env b1 b2 else Nothing
  eqE env (RFree _ v1 b1) (RFree _ v2 b2) = if eqL env v1 v2 then eqE env b1 b2 else Nothing
  eqE env (RReleaseReuse _ v1 b1) (RReleaseReuse _ v2 b2) = if eqL env v1 v2 then eqE env b1 b2 else Nothing
  eqE env (RReuseOffer _ s1 d1 u1 b1) (RReuseOffer _ s2 d2 u2 b2) =
      if eqL env s1 s2 && eqLs env d1 d2 && eqLs env u1 u2 then eqE env b1 b2 else Nothing
  eqE env (RLoop _ ps1 i1 pd1 b1) (RLoop _ ps2 i2 pd2 b2) =
      if eqLs env i1 i2 && eqLs env pd1 pd2 && eqReps (map snd ps1) (map snd ps2)
         then bindAll env (map fst ps1) (map fst ps2) >>= \env1 => eqE env1 b1 b2
         else Nothing
  eqE env (RLoopContinue _ a1 pd1) (RLoopContinue _ a2 pd2) =
      if eqLs env a1 a2 && eqLs env pd1 pd2 then Just env else Nothing
  eqE _ _ _ = Nothing

  eqMaybe : Env -> Maybe RCExp -> Maybe RCExp -> Maybe Env
  eqMaybe env Nothing Nothing = Just env
  eqMaybe env (Just x) (Just y) = eqE env x y
  eqMaybe _ _ _ = Nothing

  eqAlts : Env -> List RConAlt -> List RConAlt -> Maybe Env
  eqAlts env [] [] = Just env
  eqAlts env (MkRConAlt n1 ci1 t1 as1 b1 :: r1) (MkRConAlt n2 ci2 t2 as2 b2 :: r2) =
      if n1 == n2 && ci1 == ci2 && t1 == t2
         then bindAll env as1 as2 >>= \env1 => eqE env1 b1 b2 >>= \env2 => eqAlts env2 r1 r2
         else Nothing
  eqAlts _ _ _ = Nothing

  eqCAlts : Env -> List RConstAlt -> List RConstAlt -> Maybe Env
  eqCAlts env [] [] = Just env
  eqCAlts env (MkRConstAlt c1 b1 :: r1) (MkRConstAlt c2 b2 :: r2) =
      if c1 == c2 then eqE env b1 b2 >>= \env1 => eqCAlts env1 r1 r2 else Nothing
  eqCAlts _ _ _ = Nothing

||| Whether two candidates are the same function up to the numbering of
||| their locals (`b` may stand in for `a`).
sameFun : Cand -> Cand -> Bool
sameFun a b =
    case (a.def, b.def) of
         (MkRCFun as1 r1 w1 body1, MkRCFun as2 r2 w2 body2) =>
             if w1 == w2 && eqRep r1 r2 && eqReps (map snd as1) (map snd as2)
                then (case bindAll (MkEnv empty empty a.name b.name) (map fst as1) (map fst as2) of
                           Nothing => False
                           Just env => isJust (eqE env body1 body2))
                else False
         _ => False

------------------------------------------------------------------------
-- One round
------------------------------------------------------------------------

||| The redirections of one round: each non-root function equal to an
||| earlier one in its bucket (roots take their places first).
redirections : SortedSet Name -> List Cand -> SortedMap Name Name
redirections roots cands =
    let buckets = foldl (\m, c => insertWith (++) c.key [c] m)
                        (the (SortedMap ShallowKey (List Cand)) empty) cands
    in foldl (\acc, (_, group) => merge acc (reverse group)) empty (SortedMap.toList buckets)
  where
    -- `reps`: the distinct functions seen so far in this bucket (newest first).
    step : (List Cand, SortedMap Name Name) -> Cand -> (List Cand, SortedMap Name Name)
    step (reps, red) c =
        case find (\r => sameFun r c) reps of
             Nothing => (c :: reps, red)
             Just r => if contains c.name roots then (c :: reps, red) else (reps, insert c.name r.name red)

    -- `group` in program order. Roots first, then the rest.
    merge : SortedMap Name Name -> List Cand -> SortedMap Name Name
    merge acc [] = acc
    merge acc [_] = acc
    merge acc group =
        let ordered = filter (\c => contains c.name roots) group ++ filter (\c => not (contains c.name roots)) group
        in snd (foldl step ([], acc) ordered)

||| Merges functions with equal bodies, up to four times (a merge can
||| make the callers of the merged functions equal in turn). A merged
||| function stays in the list, out of the later rounds, until the final
||| `pruneDeadDefs`: a constant constructor's closure fields are not
||| renamed (see `renameNamesR`), so something may still refer to it.
export
dedupFuns : (roots : List Name) -> List (Name, RCDef) -> List (Name, RCDef)
dedupFuns roots defs =
    let rootSet = SortedSet.fromList roots
    in pruneDeadDefs roots (map (\c => (c.name, c.def)) (go rootSet 4 empty (map (uncurry mkCand) defs)))
  where
    go : SortedSet Name -> Nat -> SortedSet Name -> List Cand -> List Cand
    go _ Z _ cs = cs
    go rootSet (S k) merged cs =
        let red = redirections rootSet (filter (\c => c.candidate && not (contains c.name merged)) cs)
        in if null (SortedMap.toList red)
              then cs
              else let f = \m => fromMaybe m (lookup m red)
                       touches = \c => any (\m => isJust (lookup m red)) (Prelude.toList c.refs)
                       renamed = map (\c => if touches c
                                                then mkCand c.name (renameNamesD f c.def)
                                                else c) cs
                   in go rootSet k (foldl (\acc, (n, _) => insert n acc) merged (SortedMap.toList red)) renamed
