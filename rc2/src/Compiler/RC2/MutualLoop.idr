module Compiler.RC2.MutualLoop

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Mutual tail recursion loop conversion pass: synthesizes a merged
-- function for each group of mutually tail-recursive functions,
-- rewriting cross-member tail calls into self-tail calls so
-- `Compiler.RC2.Loop` can subsequently convert them into `goto`-based
-- loops. See `rc2/doc/loop-conversion.md`'s "Compiler.RC2.MutualLoop:
-- mutual tail recursion" section for the full design, the renaming
-- and arity-padding invariants this pass must get right on its own
-- (it never goes through `annotate`, so ownership is preserved only
-- by pure renaming, not re-decided), and its documented interaction
-- with native-shadow promotion in `Compiler.RC2.Loop`.
--
-- Scope: this pass only merges genuine cycles of size >= 2 in the
-- *tail-call* graph (via strongly-connected-components, so indirect
-- cycles through several functions are found too, not just direct
-- pairs). A group of size 1 is ordinary (possibly self-recursive)
-- output Compiler.RC2.Loop already handles on its own; this pass
-- leaves it alone entirely. A call wrapped in a `LazyReason` is not
-- considered a tail-call edge at all (matches Compiler.RC2.Loop's own
-- restriction).

import Compiler.RC2.RCExp
import Compiler.RC2.Loop
import Compiler.RC2.Util

import Core.CompileExpr
import Core.Context
import Core.Core
import Core.FC
import Core.TT

import Data.List
import Data.SortedMap
import Data.SortedSet
import Data.Vect

%default covering

-- `Renaming`/`renameRCExp` (substitution, used by `buildGroup` below)
-- lives in Compiler.RC2.Loop -- shared with its own native-shadow-
-- promotion rewrite. `buildGroup` only ever renames each member's own
-- *top-level argument* ids onto the merged function's shared slot ids
-- (arity unification, genuinely needed regardless); it no longer also
-- renames every *internally*-bound id to dodge cross-member
-- collisions, since every id in the whole program is already unique
-- from the moment `Compiler.RC2.RC.normalizeDef` first assigns it --
-- see `Compiler.RC2.Util`'s own `VarId` doc comment.

------------------------------------------------------------------------
-- Tail-call target collection: read-only sibling of Compiler.RC2.Loop's
-- own tail-position tree walk, over the exact same structural notion
-- of "tail position" -- rather than maintaining a second, independent
-- case-for-case copy of that walk here (a real risk of the two
-- silently drifting apart on what counts as a tail position), this is
-- just `mapTailAppNames` itself with an always-declining `f`, keeping
-- only the name set it collects and discarding the (unmodified) tree.
tailCallTargets : RCExp -> SortedSet Name
tailCallTargets body = let (names, _, _) = mapTailAppNames (\_, _, _ => Nothing) body in names

------------------------------------------------------------------------
-- Strongly-connected components of the tail-call graph (Tarjan), so
-- indirect cycles (A -> B -> C -> A) are found, not just direct pairs.

||| public export (not just export) so the type alias's own definition,
||| not just its name, is visible for unification outside this module --
||| Compiler.RC2.Inline reuses this same tail-call graph shape for its
||| own whole-program call graph, rather than reimplementing Tarjan.
public export
Graph : Type
Graph = SortedMap Name (SortedSet Name)

record TState where
  constructor MkTState
  index     : SortedMap Name Nat
  lowlink   : SortedMap Name Nat
  onStack   : SortedSet Name
  stack     : List Name
  sccs      : List (List Name)
  -- Next fresh Tarjan index to assign. Carried explicitly rather than
  -- derived as `length (SortedMap.toList (index st))` (the original
  -- implementation, found via profiling a large real program's own
  -- `rc2: Mutual loop` timing) -- that re-walks and re-counts the
  -- *entire* `index` map from scratch on every single node visited,
  -- turning Tarjan's own linear-time guarantee into O(n^2) over the
  -- whole tail-call graph. A plain counter, incremented once per newly
  -- discovered node, is the standard O(1)-per-assignment approach.
  nextIndex : Nat

total initTState : TState
initTState = MkTState empty empty empty [] [] 0


||| Each SCC is prepended as it's found, so a caller's own component
||| ends up *earlier* in the result than a callee's -- reverse the list
||| for callees-before-callers (bottom-up) processing order.
export
tarjanSCCs : Graph -> List (List Name)
tarjanSCCs graph =
    sccs $ foldl (\st, v => if isJust (lookup v (index st)) then st else strongConnect graph v st) initTState $ keys graph
  where
    ||| Pop `stack` down to and including `v`; returns (that component's
    ||| members, the remaining stack).
    total popUntil : Name -> List Name -> (List Name, List Name)
    popUntil v [] = ([], [])
    popUntil v (x :: xs) =
        if x == v
        then ([x], xs)
        else let (popped, rest) = popUntil v xs
              in (x :: popped, rest)
    visitSucc : Graph -> Name -> TState -> Name -> TState
    strongConnect : Graph -> Name -> TState -> TState
    strongConnect graph v st0 =
        let idx  = nextIndex st0
            st1  = MkTState (insert v idx (index st0)) (insert v idx (lowlink st0))
                            (SortedSet.insert v (onStack st0)) (v :: stack st0) (sccs st0) (idx + 1)
            st2  = maybe st1 (foldl (visitSucc graph v) st1) $ lookup v graph
        in if (lookup v (lowlink st2)) == (lookup v (index st2))
            then let (comp, rest) = popUntil v (stack st2)
                     onStack' = foldl (flip SortedSet.delete) (onStack st2) comp
                  in MkTState (index st2) (lowlink st2) onStack' rest (comp :: sccs st2) (nextIndex st2)
            else st2

    visitSucc graph v st w =
        case lookup w (index st) of
            Nothing =>
                let st' = strongConnect graph w st
                    wLow = fromMaybe 0 (lookup w (lowlink st'))
                    vLow = fromMaybe 0 (lookup v (lowlink st'))
                in MkTState (index st') (insert v (min vLow wLow) (lowlink st')) (onStack st') (stack st') (sccs st') (nextIndex st')
            Just wIdx =>
                if contains w (onStack st)
                then let vLow = fromMaybe 0 (lookup v (lowlink st))
                        in MkTState (index st) (insert v (min vLow wIdx) (lowlink st)) (onStack st) (stack st) (sccs st) (nextIndex st)
                else st

------------------------------------------------------------------------
-- Synthesising one merged group.

buildGroup : {auto r : Ref FreshId Int} -> {auto v : Ref VarId Int}
          -> SortedMap Name (List (Maybe PrimType))
          -> SortedSet Name
          -> SortedMap Name (List Int, RCExp)
          -> List Name
          -> Core (List (Name, RCDef), (Name, SortedSet Int))
buildGroup calleeTable existingNames memberDefs groupNames = do
    -- Deterministic order (SortedSet's own Foldable, Prelude.toList,
    -- is sorted by `Ord Name`), so tag assignment doesn't depend on
    -- SCC-traversal order.
    let ordered = Prelude.toList (SortedSet.fromList groupNames)
    members <- the (Core (List (Name, (List Int, RCExp)))) $
                 traverse (\n => case lookup n memberDefs of
                                      Just def => pure (n, def)
                                      Nothing => throw $ InternalError "[rc2] MutualLoop: SCC member not found") ordered
    -- `membersWithTag` is the single source of truth for the name<->tag
    -- correspondence: both `alts`/`wrappers` below take their `tag_i`
    -- straight from this same zip, and `tagOf` (needed separately by
    -- `rewriteGroupTailCalls`, which looks up *arbitrary* tail-call
    -- targets, not just this group's own members in order) is derived
    -- from it too -- so there is no second, independently-fallible
    -- `lookup name_i tagOf` on the hot path that could ever silently
    -- default to tag 0 for a member `tagOf` genuinely doesn't have.
    let tagList : List Int = map (\i => the Int (cast i)) [0 .. length members `minus` 1]
    -- Slots are shared by position only within one class of parameter:
    -- the native type `Compiler.RC2.Loop` would promote it to on its own
    -- member (`callArgOrOpNativeType`), or `Nothing`. A native class's
    -- values all have that type, so promoting its slot is sound; a
    -- `Nothing` slot may hold values of different types, so Loop must
    -- never promote it (`noPromote`). rc2/doc/loop-conversion.md's
    -- "MutualLoop" section and its "Bugs found" 8.
    let classesOf : List (List (Maybe PrimType)) :=
            map (\(_, (args, body)) => map (\p => callArgOrOpNativeType calleeTable p body) args) members
    let classes : List (Maybe PrimType) := nub (concat classesOf)
    let widths : List Nat := map (\k => foldl max Z (map (\ks => length (filter (== k) ks)) classesOf)) classes
    let classOffsets : List Nat := reverse (snd (foldl (\ao, a => (fst ao + a, fst ao :: snd ao)) (the (Nat, List Nat) (Z, [])) widths))
    let slotCount = sum widths
    let offsetOf : Maybe PrimType -> Nat
        offsetOf k = fromMaybe Z (lookup k (zip classes classOffsets))
    -- Each parameter's slot: its class's offset plus how many earlier
    -- parameters of the same member share its class.
    let positionsOf : List (Maybe PrimType) -> List Nat
        positionsOf ks = zipWith (\i, k => offsetOf k + length (filter (== k) (take i ks))) [0 .. length ks] ks
    let positions : List (List Nat) := map positionsOf classesOf
    let membersWithTag = zip members tagList
    let tagOf : SortedMap Name (Int, List Nat) := SortedMap.fromList (zipWith (\((n, _), t), ps => (n, (t, ps))) membersWithTag positions)
    mergedName <- freshName existingNames
    tagId <- freshVarId
    slotIds <- traverse (const freshVarId) (replicate slotCount ())
    let slotAt : Nat -> Int
        slotAt g = fromMaybe 0 (lookup g (zip [0 .. slotCount] slotIds))
    alts <- traverse (\(((name_i, (args_i, body_i)), tag_i), pos_i) => do
                let ren : Renaming = SortedMap.fromList (zip args_i (map slotAt pos_i))
                let renamedBody = renameRCExp ren body_i
                pure $ MkRConstAlt (I64 (cast tag_i)) (rewriteGroupTailCalls mergedName slotCount tagOf renamedBody))
              (zip membersWithTag positions)
    let mergedBody = RConstCase EmptyFC (RCLoc tagId) alts
                        (Just (RCrash EmptyFC "[rc2] internal: MutualLoop tag dispatch fell through"))
    let mergedDef = MkRCFun (map (\i => (i, RBoxed)) (tagId :: slotIds)) RBoxed False mergedBody
    let wrappers = map (\(((name_i, (args_i, _)), tag_i), pos_i) =>
                      (name_i, MkRCFun (map (\i => (i, RBoxed)) args_i) RBoxed False
                            (RAppName EmptyFC Nothing mergedName (RCConst (I64 (cast tag_i)) :: placed slotCount pos_i (map RCLoc args_i)))))
                    (zip membersWithTag positions)
    let boxedSlots : SortedSet Int :=
            SortedSet.fromList (concatMap (\(k, o, w) => if isJust k then [] else map slotAt (take w [o ..]))
                                          (zip3 classes classOffsets widths))
    pure ((mergedName, mergedDef) :: wrappers, (mergedName, boxedSlots))
  where
    ||| `args` at their slots `pos` among `slotCount`, `RCNull` everywhere else.
    placed : Nat -> List Nat -> List RCLocal -> List RCLocal
    placed slotCount pos args =
        let at = zip pos args
        in map (\g => fromMaybe RCNull (lookup g at)) (take slotCount [0 ..])

    freshName : {auto r : Ref FreshId Int} -> SortedSet Name -> Core Name
    freshName existing = do
        let cand = MN "rc2_mutualLoop" !(freshId{r})
        if contains cand existing
           then freshName{r} existing else pure cand

    ||| Rewrite every tail-position call (self- or cross-member alike)
    ||| within an already-renamed member body into a tail call to the
    ||| merged function itself, carrying the target's tag and its
    ||| arguments in the target's own slots -- see the module note's
    ||| ownership/invariant discussion for why no extra drop/pad-related
    ||| bookkeeping is needed here beyond this substitution.
    rewriteGroupTailCalls : Name -> Nat -> SortedMap Name (Int, List Nat) -> RCExp -> RCExp
    rewriteGroupTailCalls mergedName slotCount tagOf body =
        let (_, _, rewritten) = mapTailAppNames
                (\fc, n, args =>
                    case lookup n tagOf of
                        Nothing => Nothing
                        Just (t, pos) => Just $ RAppName fc Nothing mergedName $
                                    RCConst (I64 (cast t)) :: placed slotCount pos args)
                body
        in rewritten

||| Whole-program pass: finds every group (size >= 2) of mutually
||| tail-recursive functions and replaces them with one synthesised
||| merged function plus a thin per-member wrapper each -- see the
||| module note for the full design. Definitions this pass doesn't
||| touch (everything outside a size->=2 group -- including ordinary,
||| possibly self-recursive, functions, and every non-`MkRCFun` def)
||| pass through completely unchanged. Also returns, per merged function,
||| the slots Loop must never promote (`buildGroup`'s `noPromote`).
export
applyMutualLoop : {auto v : Ref VarId Int} -> List (Name, RCDef) -> Core (List (Name, RCDef), SortedMap Name (SortedSet Int))
applyMutualLoop defs = do
    _ <- newRef FreshId 0
    let memberDefs = SortedMap.fromList $ mapMaybe
            (\(n, d) => case d of
                             MkRCFun args _ _ body => Just (n, (map fst args, body))
                             _ => Nothing)
            defs
    let graph = buildGraph memberDefs
    let groups = filter (\g => length g >= 2) (tarjanSCCs graph)
    let existingNames = SortedSet.fromList (map (\(n, _) => n) defs)
    let calleeTable = buildCalleeTable defs
    built <- traverse (buildGroup calleeTable existingNames memberDefs) groups
    let newDefs = foldr (++) [] (map fst built)
    let mergedMemberNames = SortedSet.fromList (concat groups)
    let untouched = filter (\(n, _) => not (contains n mergedMemberNames)) defs
    pure (untouched ++ newDefs, SortedMap.fromList (map snd built))
  where
    buildGraph : SortedMap Name (List Int, RCExp) -> Graph
    buildGraph memberDefs =
        let allNames = SortedSet.fromList (map (\(n, _) => n) (SortedMap.toList memberDefs))
        in fromList $ map (\(n, (_, body)) =>
            (n, SortedSet.fromList (filter (\t => contains t allNames) (Prelude.toList (tailCallTargets body)))))
            (SortedMap.toList memberDefs)
