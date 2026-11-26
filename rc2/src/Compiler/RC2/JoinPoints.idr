||| Tail subtrees of one function that are equal up to the numbering of
||| their locals become one join point the copies jump to
||| (`rc2/doc/join-points.md`). Runs last, after every pass that rewrites
||| a body, so only `Emit` has to know the nodes. Disable with
||| `--directive nojoinpoints`.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Compiler.RC2.JoinPoints

import Compiler.RC2.FunDedup
import Compiler.RC2.LateInline
import Compiler.RC2.Pretty
import Compiler.RC2.RCExp
import Compiler.RC2.Rewrite

import Core.FC

import Data.List
import Data.Maybe
import Data.SortedMap
import Data.SortedSet

%default covering

||| The smallest subtree worth a join point, in nodes.
minJoinNodes : Nat
minJoinNodes = 8

||| The same inside a loop, where each jump moves its arguments on every
||| iteration (rc2/doc/join-points.md, "Measured").
minJoinNodesInLoop : Nat
minJoinNodesInLoop = 24

-- A tail subtree: where it is (the child indexes from the body, last
-- first, and its first node's number in a preorder walk), the path of the
-- region it is a tail of (the body, or a `let`'s value), and that of the
-- innermost `RLoop` above it.
record Cand where
  constructor MkCand
  size : Nat
  path : List Nat
  start : Nat
  region : List Nat
  loop : Maybe (List Nat)
  expr : RCExp

-- What `joinIn` has chosen so far.
record Acc where
  constructor MkAcc
  ||| Each member's path and the jump that replaces it.
  jumps : SortedMap (List Nat) RCExp
  ||| Each join point's path and the `RJoin`s to put around the node there.
  joins : SortedMap (List Nat) (List (RCExp -> RCExp))
  ||| The preorder span of every member chosen, by its first node.
  covered : SortedMap Nat Nat
  label : Nat
  nextId : Int

-- What the free locals of a member must be, per local of the function.
record Locals where
  constructor MkLocals
  reps : SortedMap LocalId Rep
  ||| Locals bound to a constructor in the C frame (`StackCon`): the cell
  ||| lives in the C block of its `let`, which a join point may be outside.
  onStack : SortedSet LocalId

-- Where each child of `e` is: in the same region as `e` (its tails are
-- tails of the region), the first node of a region of its own (a `let`'s
-- value), or neither. A loop's body is in its loop's region: its tails
-- leave the region or continue the loop.
data Place = Same | Region | Neither

-- One function's body with its repeated tail subtrees made jumps.
joinIn : List (LocalId, Rep) -> RCExp -> RCExp
joinIn args body =
    let (_, cands) = collect [] Z [] Nothing body []
        bySize = foldl (\m, c => insertWith (++) c.size [c] m) (the (SortedMap Nat (List Cand)) empty) cands
        groups = filter (\g => length g >= 2) (map snd (reverse (SortedMap.toList bySize)))
    in case groups of
            [] => body
            _ => let locals = localsOf args body
                     acc = foldl (doSize locals) (MkAcc empty empty empty Z (maxId args body + 1)) groups
                 in if null acc.jumps then body else rebuild acc [] body
  where
    kidPlaces : RCExp -> List Place
    kidPlaces (RLet {}) = [Region, Same]
    kidPlaces (RLoop {}) = [Same]
    kidPlaces e = replicate (length (children e)) (if isJust (tailChildren e) then Same else Neither)

    size : RCExp -> Nat
    size e = S (sum (map size (children e)))

    -- Every subtree of `e` of at least `minJoinNodes` nodes (`minJoinNodesInLoop`
    -- in a loop) in a tail of its region, and the size of `e`.
    collect : List Nat -> Nat -> List Nat -> Maybe (List Nat) -> RCExp -> List Cand -> (Nat, List Cand)
    collect path start region loop e acc =
        let loop' = case e of
                         RLoop {} => Just path
                         _ => loop
            (n, acc') = foldl (\(s, a), (i, pl, k) =>
                                  case pl of
                                       Same => step s a (i :: path) region loop' k
                                       Region => step s a (i :: path) (i :: path) loop' k
                                       Neither => (s + size k, a))
                              (Z, acc) (zip3 [0 .. length (children e)] (kidPlaces e) (children e))
            sz = S n
            least = if isJust loop then minJoinNodesInLoop else minJoinNodes
        in (sz, if sz >= least then MkCand sz path start region loop e :: acc' else acc')
      where
        step : Nat -> List Cand -> List Nat -> List Nat -> Maybe (List Nat) -> RCExp -> (Nat, List Cand)
        step s a here r l k = let (s', a') = collect here (start + 1 + s) r l k a in (s + s', a')

    -- The locals `e` reads that it does not bind, in the order a preorder walk
    -- first reads them. `mentionedLocals` has every read; the walk only orders them.
    freeOrder : RCExp -> List LocalId
    freeOrder e =
        let bound = SortedSet.fromList (collectBoundIds e)
            free = filter (\i => not (contains i bound)) (mapMaybe idOf (Prelude.toList (mentionedLocals e)))
            freeSet = SortedSet.fromList free
            (walked, seen) = foldl (step freeSet) ([], empty) (mapMaybe idOf (reads [] [e]))
        in reverse walked ++ filter (\i => not (contains i seen)) free
      where
        own : RCExp -> List RCLocal
        own x = directReads x ++ case x of
                                      RDrop _ vs _ => map RCLoc vs
                                      RReleaseReuse _ v _ => [RCLoc v]
                                      RReuseOffer _ sc _ _ _ => [RCLoc sc]
                                      RCon _ _ _ _ _ r => toList r
                                      _ => []

        reads : List RCLocal -> List RCExp -> List RCLocal
        reads acc [] = reverse acc
        reads acc (x :: xs) = reads (reverse (own x) ++ acc) (children x ++ xs)

        step : SortedSet LocalId -> (List LocalId, SortedSet LocalId) -> LocalId -> (List LocalId, SortedSet LocalId)
        step free (acc, seen) i =
            if contains i free && not (contains i seen) then (i :: acc, insert i seen) else (acc, seen)

    -- The locals a reuse in `e` names: the C slot of a reuse is named after the
    -- local it reuses, so a member may not take such a local as a parameter.
    reuseNames : RCExp -> SortedSet LocalId
    reuseNames e = go empty [e]
      where
        go : SortedSet LocalId -> List RCExp -> SortedSet LocalId
        go acc [] = acc
        go acc (x :: xs) =
            let acc' = case x of
                            RCon _ _ _ _ _ (Just (RCLoc v)) => insert v acc
                            RReleaseReuse _ v _ => insert v acc
                            RReuseOffer _ sc _ _ _ => insert sc acc
                            _ => acc
            in go acc' (children x ++ xs)

    -- The `Rep` of every local the body binds, and which are on the stack.
    localsOf : List (LocalId, Rep) -> RCExp -> Locals
    localsOf args body = go (MkLocals (SortedMap.fromList args) empty) [body]
      where
        isStruct : Locals -> RCLocal -> Bool
        isStruct acc (RCLoc i) = case lookup i acc.reps of
                                      Just (RRet _ _) => True
                                      _ => False
        isStruct _ _ = False

        go : Locals -> List RCExp -> Locals
        go acc [] = acc
        go acc (x :: xs) =
            let acc' = case x of
                            RLet _ v r (RStackCon {}) _ => { reps $= insert v r, onStack $= insert v } acc
                            RLet _ v r _ _ => { reps $= insert v r } acc
                            RLoop _ ps _ _ _ => { reps $= \m => foldl (\m', (i, r) => insert i r m') m ps } acc
                            -- The fields of a struct (`RRet`) are what its layout says, not
                            -- Boxed (`DualABI.fieldReps`): they get no `Rep`, so no member
                            -- passes one.
                            RConCase _ sc alts _ =>
                                if isStruct acc sc then acc
                                   else { reps $= \m => foldl (\m', (MkRConAlt _ _ _ as _) => foldl (\m'', a => insert a RBoxed m'') m' as) m alts } acc
                            _ => acc
            in go acc' (children x ++ xs)

    -- The largest id the function uses, so the parameters can take fresh ones.
    maxId : List (LocalId, Rep) -> RCExp -> Int
    maxId args body =
        foldl (\m, i => max m i.num) 0
              (map fst args ++ collectBoundIds body ++ mapMaybe idOf (Prelude.toList (mentionedLocals body)))

    repOf : Locals -> LocalId -> Maybe Rep
    repOf locals i = lookup i locals.reps

    -- A parameter takes a Boxed or a native value; `RInlineNative` has no
    -- variable of its own, and a struct is not passed this way.
    passable : Locals -> RCExp -> List LocalId -> Bool
    passable locals e free =
        let reused = reuseNames e
        in all (\i => case repOf locals i of
                           Just RBoxed => ok i reused
                           Just (RNative _) => ok i reused
                           _ => False) free
      where
        ok : LocalId -> SortedSet LocalId -> Bool
        ok i reused = not (contains i locals.onStack) && not (contains i reused)

    sameReps : Locals -> List LocalId -> List LocalId -> Bool
    sameReps locals a b =
        length a == length b
          && all (\(x, y) => map prettyRep (repOf locals x) == map prettyRep (repOf locals y)) (zip a b)

    classes : List (Cand, List LocalId) -> List (List (Cand, List LocalId))
    classes [] = []
    classes (c :: cs) =
        let same = \d => sameUpToLocals (snd c) (snd d) (fst c).expr (fst d).expr
            (here, rest) = partition same cs
        in (c :: here) :: classes rest

    -- Members in one region and the same innermost loop: their common
    -- ancestor is then in a tail of that region and inside that loop, so a
    -- `continue` in the body still continues it.
    byLoop : List (Cand, List LocalId) -> List (List (Cand, List LocalId))
    byLoop [] = []
    byLoop (c :: cs) =
        let (here, rest) = partition (\d => (fst d).region == (fst c).region && (fst d).loop == (fst c).loop) cs
        in (c :: here) :: byLoop rest

    commonPrefix : List Nat -> List Nat -> List Nat
    commonPrefix (x :: xs) (y :: ys) = if x == y then x :: commonPrefix xs ys else []
    commonPrefix _ _ = []

    makeJoin : Locals -> Acc -> List (Cand, List LocalId) -> Acc
    makeJoin locals acc cl@((c, free) :: rest) =
        let members = (c, free) :: filter (\(_, fr) => sameReps locals free fr) rest
        in if length members < 2 then acc else
           let params = zipWith (\i, k => (MkLocalId (acc.nextId + cast k), fromMaybe RBoxed (repOf locals i))) free [0 .. length free]
               ren = SortedMap.fromList (zip free (map fst params))
               lca = reverse (foldl (\p, (d, _) => commonPrefix p (reverse d.path)) (reverse c.path) members)
               label = acc.label
               wrap = \scope => RJoin emptyFC label params scope (renameRCExp ren c.expr)
           in MkAcc (foldl (\m, (d, fr) => insert d.path (RJump emptyFC label (map RCLoc fr)) m) acc.jumps members)
                    (insertWith (\new, old => old ++ new) lca [wrap] acc.joins)
                    (foldl (\m, (d, _) => insert d.start (d.start + d.size) m) acc.covered members)
                    (S label)
                    (acc.nextId + cast (length free))
    makeJoin _ acc [] = acc

    -- One size: candidates of one size never nest, so what this group
    -- covers only matters to the smaller ones after it. Only those with as
    -- many free locals and the same constants are compared, in the order the
    -- classes first appear (rc2/doc/shared-subtrees.md, on `leafHash`).
    doSize : Locals -> Acc -> List Cand -> Acc
    doSize locals acc group =
        let uncovered = filter (\c => not (inside c)) group
            here = filter (\(c, fr) => passable locals c.expr fr) (map (\c => (c, freeOrder c.expr)) uncovered)
            keyed = foldl (\m, cf => insertWith (++) (length (snd cf), leafHash (fst cf).expr) [cf] m)
                          (the (SortedMap (Nat, Int) (List (Cand, List LocalId))) empty) here
            found = filter (\cl => length cl >= 2)
                           (concatMap byLoop (concatMap (classes . reverse) (map snd (SortedMap.toList keyed))))
        in foldl (makeJoin locals) acc (sortBy (\a, b => compare (firstStart a) (firstStart b)) (map (sortBy (\a, b => compare (fst a).start (fst b).start)) found))
      where
        firstStart : List (Cand, List LocalId) -> Nat
        firstStart cl = maybe Z (start . fst) (head' cl)

        inside : Cand -> Bool
        inside c = case fst (lookupBetween (S c.start) acc.covered) of
                        Just (_, end) => c.start < end
                        Nothing => False

    -- `e` (at `path`, last index first) with each member made its jump and
    -- each join point put around the node it is at.
    rebuild : Acc -> List Nat -> RCExp -> RCExp
    rebuild acc path e =
        let inner = case lookup path acc.jumps of
                         Just j => j
                         Nothing => withChildren e (zipWith (\i, k => rebuild acc (i :: path) k) [0 .. length (children e)] (children e))
        in foldl (\x, w => w x) inner (fromMaybe [] (lookup path acc.joins))

||| Every function's repeated tail subtrees made jumps to one join point
||| (rc2/doc/join-points.md).
export
applyJoinPoints : RCDef -> RCDef
applyJoinPoints (MkRCFun args r w body) = MkRCFun args r w (joinIn args body)
applyJoinPoints d = d
