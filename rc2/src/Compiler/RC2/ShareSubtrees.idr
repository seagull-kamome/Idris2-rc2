||| Subtrees of one function that are equal up to the numbering of their
||| locals become one new function, called from where each copy was
||| (`rc2/doc/shared-subtrees.md`). Runs before RC, so every later pass
||| treats the new function like any other. Disable with
||| `--directive nosharesubtrees`.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Compiler.RC2.ShareSubtrees

import Compiler.RC2.Emit.Util
import Compiler.RC2.FunDedup
import Compiler.RC2.MutualLoop
import Compiler.RC2.RCExp

import Core.FC
import Core.Name
import Core.TT

import Data.List
import Data.Maybe
import Data.SortedMap
import Data.SortedSet

%default covering

||| The smallest subtree worth a function of its own, in nodes.
minNodes : Nat
minNodes = 24

-- A subtree: where it is (the child indexes from the body, last first, and
-- its first node's number in a preorder walk), and whether that is a tail
-- position of the function.
record Cand where
  constructor MkCand
  size : Nat
  path : List Nat
  start : Nat
  tail : Bool
  expr : RCExp

-- What `shareIn` has chosen so far.
record Acc where
  constructor MkAcc
  calls : List (List Nat, RCExp)
  defs : List (Name, RCDef)
  ||| The preorder span of every subtree chosen, by its first node.
  covered : SortedMap Nat Nat
  next : Nat

-- One function's body with its repeated subtrees called instead, and the
-- functions they became.
shareIn : Name -> SortedSet Name -> RCExp -> (RCExp, List (Name, RCDef))
shareIn f scc body =
    let (_, cands) = collect [] Z True body []
        bySize = foldl (\m, c => insertWith (++) c.size [c] m) (the (SortedMap Nat (List Cand)) empty) cands
        groups = filter (\g => length g >= 2) (map snd (reverse (SortedMap.toList bySize)))
        acc = foldl doSize (MkAcc [] [] empty Z) groups
    in (replaceAt (map (\(p, r) => (reverse p, r)) acc.calls) body, acc.defs)
  where
    freeOrder : RCExp -> List LocalId
    freeOrder e =
        let free = SortedSet.fromList (mapMaybe idOf (Prelude.toList (freeLocalsR e)))
            (walked, seen) = foldl (step free) ([], empty) (mapMaybe idOf (reads [] [e]))
        in reverse walked ++ filter (\i => not (contains i seen)) (Prelude.toList free)
      where
        -- A work list: the walk is over the whole subtree.
        reads : List RCLocal -> List RCExp -> List RCLocal
        reads acc [] = reverse acc
        reads acc (x :: xs) = reads (reverse (directReads x) ++ acc) (children x ++ xs)

        step : SortedSet LocalId -> (List LocalId, SortedSet LocalId) -> LocalId -> (List LocalId, SortedSet LocalId)
        step free (acc, seen) i =
            if contains i free && not (contains i seen) then (i :: acc, insert i seen) else (acc, seen)

    -- Which children of `e` are in tail position, given that `e` is.
    tailKids : RCExp -> List Bool
    tailKids (RLet {}) = [False, True]
    tailKids e = replicate (length (children e)) (isJust (tailChildren e))

    -- The size of `e`; every subtree of it of at least `minNodes` nodes is
    -- added to `acc`.
    collect : List Nat -> Nat -> Bool -> RCExp -> List Cand -> (Nat, List Cand)
    collect path start tl e acc =
        let ks = children e
            (n, acc') = foldl (\(s, a), (i, t, k) => let (s', a') = collect (i :: path) (start + 1 + s) (tl && t) k a in (s + s', a'))
                              (Z, acc) (zip3 [0 .. length ks] (tailKids e) ks)
            size = S n
        in (size, if size >= minNodes then MkCand size path start tl e :: acc' else acc')

    -- `e` with the subtree at each path (first index first) replaced.
    replaceAt : List (List Nat, RCExp) -> RCExp -> RCExp
    replaceAt [] e = e
    replaceAt reps e = case find (null . fst) reps of
        Just (_, r) => r
        Nothing =>
            let ks = children e
            in withChildren e (zipWith (\i, k => replaceAt (mapMaybe (under i) reps) k) [0 .. length ks] ks)
      where
        under : Nat -> (List Nat, RCExp) -> Maybe (List Nat, RCExp)
        under i (j :: rest, r) = if j == i then Just (rest, r) else Nothing
        under _ ([], _) = Nothing

    -- rc2/doc/shared-subtrees.md: the argument limit, and a tail call into
    -- the function's own cycle, which only a copy in tail position makes.
    eligible : (Cand, List LocalId) -> Bool
    eligible (c, free) = length free <= MaxExtractFunArgs
                         && not (c.tail && any (\n => contains n scc) (Prelude.toList (tailCallTargets c.expr)))

    classes : List (Cand, List LocalId) -> List (List (Cand, List LocalId))
    classes [] = []
    classes (c :: cs) =
        let same = \d => sameUpToLocals (snd c) (snd d) (fst c).expr (fst d).expr
            (here, rest) = partition same cs
        in (c :: here) :: classes rest

    share : Acc -> List (Cand, List LocalId) -> Acc
    share acc cl@((c, free) :: _) =
        let name = MN ("rc2_share_" ++ cName f) (cast acc.next)
            call = \fr => RAppName emptyFC Nothing name (map RCLoc fr)
        in MkAcc (map (\(d, fr) => (d.path, call fr)) cl ++ acc.calls)
                 ((name, MkRCFun (map (\p => (p, RBoxed)) free) RBoxed False c.expr) :: acc.defs)
                 (foldl (\m, (d, _) => insert d.start (d.start + d.size) m) acc.covered cl)
                 (S acc.next)
    share acc [] = acc

    -- One size: candidates of one size never nest, so what this group
    -- covers only matters to the smaller ones after it. Only those with as
    -- many free locals and the same constants are compared.
    doSize : Acc -> List Cand -> Acc
    doSize acc group =
        let uncovered = filter (\c => not (inside c)) group
            here = filter eligible (map (\c => (c, freeOrder c.expr)) uncovered)
            keyed = foldl (\m, cf => insertWith (++) (length (snd cf), leafHash (fst cf).expr) [cf] m)
                          (the (SortedMap (Nat, Int) (List (Cand, List LocalId))) empty) here
            -- In the order the classes first appear in the body, not the
            -- buckets': `leafHash` reads `show` of constants, which differs
            -- between backends (a `Double`'s), and the order names the new
            -- functions, so a compiler built by rc2 would write other C than
            -- one built by Chez (rc2/doc/shared-subtrees.md).
            found = filter (\cl => length cl >= 2) (concatMap (classes . reverse) (map snd (SortedMap.toList keyed)))
        in foldl share acc (sortBy (\a, b => compare (firstStart a) (firstStart b)) found)
      where
        firstStart : List (Cand, List LocalId) -> Nat
        firstStart cl = foldl (\m, (c, _) => min m c.start) (maybe Z (start . fst) (head' cl)) cl

        -- In a subtree chosen before: they do not overlap, so the one
        -- starting last at or before `c` is the only one to look at.
        inside : Cand -> Bool
        inside c = case fst (lookupBetween (S c.start) acc.covered) of
                        Just (_, end) => c.start < end
                        Nothing => False

||| Every function's repeated subtrees made calls of new functions
||| (rc2/doc/shared-subtrees.md).
export
applyShareSubtrees : List (Name, RCDef) -> List (Name, RCDef)
applyShareSubtrees defs =
    -- A `let`, not a `where`: a `where` value is computed again at each use
    -- (doc/constant-constructor-specialization.md, "The `where`-clause trap").
    let sccs = componentsOf defs
    in concatMap (\(n, d) => case d of
          MkRCFun args r w body =>
              let (body', new) = shareIn n (fromMaybe (singleton n) (lookup n sccs)) body
              in (n, MkRCFun args r w body') :: new
          _ => [(n, d)]) defs
  where
    -- Each function's component of the tail-call graph.
    componentsOf : List (Name, RCDef) -> SortedMap Name (SortedSet Name)
    componentsOf ds =
        let graph = SortedMap.fromList (mapMaybe (\(n, d) => case d of
                                                     MkRCFun _ _ _ body => Just (n, tailCallTargets body)
                                                     _ => Nothing) ds)
        in foldl (\m, comp => let s = SortedSet.fromList comp
                              in foldl (\m', n => insert n s m') m comp) empty (tarjanSCCs graph)
