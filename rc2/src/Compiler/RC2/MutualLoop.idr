module Compiler.RC2.MutualLoop

-- Mutual tail recursion loop conversion: a whole-program pass (unlike
-- Compiler.RC2.Reuse/Compiler.RC2.Loop, which each work one definition
-- at a time) that runs after Reuse and *before* Loop (see RC2.idr's
-- toRCDefs).
--
-- The key idea: rather than inventing a new IR shape for "a tail call
-- to a *different* member of my own mutually-recursive group", this
-- pass synthesises, for each group of >= 2 functions that mutually
-- tail-call each other, a single new merged function whose body is a
-- plain `RConstCase` switching on a small integer tag -- one alt per
-- original group member -- and rewrites *every* tail call within the
-- group (self- or cross-member alike) into an ordinary tail call to
-- that merged function itself, carrying the target's tag and (padded)
-- arguments. From that merged function's own point of view, every one
-- of those is now just a plain self-tail-call -- exactly the shape
-- Compiler.RC2.Loop (which runs immediately afterward) already knows
-- how to turn into a `goto`. So this module needs no help from
-- Compiler.RC2.Emit at all: it only ever produces ordinary `RConstCase`/
-- `RAppName`/`MkRCFun` shapes that already have a mechanical, verified
-- lowering.
--
-- Each original member's own top-level name keeps working as a normal,
-- independently-callable function (for external callers, and for any
-- *non*-tail use, e.g. being passed around as a closure) -- it becomes
-- a thin wrapper that just calls the merged function once with its own
-- tag and arguments and returns whatever comes back.
--
-- Because all of rc2's own calling convention is uniformly `Value*`,
-- the merged function's parameters are just `tag, slot_0 .. slot_k`
-- (k = the largest arity among the group's members) -- every ordinary
-- `RCLocal`, nothing backend-specific. Members with a smaller arity
-- simply never reference their own unused trailing slots, and every
-- caller (wrapper or in-group transition) always pads them with
-- `RCNull`.
--
-- Ownership: Compiler.RC2.RC's `annotate` (Phase 2) already decided
-- every member's own dup/drop/move behaviour for its original
-- arguments and locals, before this pass ever runs -- merging doesn't
-- change any of that, it only changes *where a tail call lands*. Two
-- things this pass does need to get right on its own, since it's
-- building genuinely new tree shape that never went through `annotate`:
--   1. Renaming: each member's own local ids (its own top-level
--      parameters *and* every RLet/RConAlt-bound id in its body) get
--      renamed to fresh, group-wide-unique ids before being spliced
--      into the merged function -- a pure, meaning-preserving
--      substitution (every existing RDup/RDrop/RFree node just moves
--      to the new id along with its target), *not* a fresh ownership
--      decision. A member's own top-level parameters specifically get
--      renamed onto the shared `slot_0 .. slot_{arity-1}` ids (not
--      arbitrary fresh ones), since those *are* the merged function's
--      real parameters.
--   2. The invariant that keeps padding safe without any extra drops:
--      whenever a transition enters member `j`, slots `< arity(j)`
--      always hold real, freshly-supplied values for `j`, and slots
--      `>= arity(j)` are always `RCNull`. This holds inductively as
--      long as *every* transition (wrapper call or in-group tail call)
--      pads unused trailing slots with `RCNull` -- which this pass
--      always does. Under that invariant, a member's own body only
--      ever needs to reason about its own `[0, arity)` slots exactly as
--      it always did (that's exactly what `annotate` already
--      determined for its original, pre-merge argument list); nothing
--      beyond that is ever read, so nothing beyond that ever needs an
--      extra drop this pass would have to invent.
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

-- `collectBoundIds`/`Renaming`/`renameRCExp` (per-member id collection
-- and substitution, used by `buildGroup` below) now live in
-- Compiler.RC2.Loop -- shared with its own native-shadow-promotion
-- rewrite, one definition instead of two kept in sync by hand. See its
-- own doc comment.

------------------------------------------------------------------------
-- Tail-call target collection (read-only sibling of Compiler.RC2.Loop's
-- `mapTailAppNames`, over the exact same structural notion of "tail
-- position" -- see its own doc comment for why the two must agree).

tailCallTargets : RCExp -> SortedSet Name
tailCallTargets (RAppName fc Nothing n _) = singleton n
tailCallTargets (RLet _ _ _ _ body) = tailCallTargets body
tailCallTargets (RDup _ _ body) = tailCallTargets body
tailCallTargets (RDrop _ _ body) = tailCallTargets body
tailCallTargets (RFree _ _ body) = tailCallTargets body
tailCallTargets (RReleaseReuse _ _ body) = tailCallTargets body
tailCallTargets (RReuseOffer _ _ _ body) = tailCallTargets body
tailCallTargets (RCmpCase _ _ _ _ t f) = union (tailCallTargets t) (tailCallTargets f)
tailCallTargets (RConCase _ _ alts mDef) =
    let altsT = map (\(MkRConAlt _ _ _ _ body) => tailCallTargets body) alts
    in concat (maybe altsT (\d => tailCallTargets d :: altsT) mDef)
tailCallTargets (RConstCase _ _ alts mDef) =
    let altsT = map (\(MkRConstAlt _ body) => tailCallTargets body) alts
    in concat (maybe altsT (\d => tailCallTargets d :: altsT) mDef)
tailCallTargets _ = empty

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
  index   : SortedMap Name Nat
  lowlink : SortedMap Name Nat
  onStack : SortedSet Name
  stack   : List Name
  sccs    : List (List Name)

initTState : TState
initTState = MkTState empty empty empty [] []

||| Pop `stack` down to and including `v`; returns (that component's
||| members, the remaining stack).
popUntil : Name -> List Name -> (List Name, List Name)
popUntil v [] = ([], [])
popUntil v (x :: xs) =
    if x == v
       then ([x], xs)
       else let (popped, rest) = popUntil v xs
            in (x :: popped, rest)

mutual
  strongConnect : Graph -> Name -> TState -> TState
  strongConnect graph v st0 =
      let idx  = length (SortedMap.toList (index st0))
          st1  = MkTState (insert v idx (index st0)) (insert v idx (lowlink st0))
                          (SortedSet.insert v (onStack st0)) (v :: stack st0) (sccs st0)
          succs = maybe [] SortedSet.toList (lookup v graph)
          st2  = foldl (visitSucc graph v) st1 succs
          vIdx = fromMaybe idx (lookup v (index st2))
          vLow = fromMaybe idx (lookup v (lowlink st2))
      in if vLow == vIdx
            then let (comp, rest) = popUntil v (stack st2)
                     onStack' = foldl (flip SortedSet.delete) (onStack st2) comp
                 in MkTState (index st2) (lowlink st2) onStack' rest (comp :: sccs st2)
            else st2

  visitSucc : Graph -> Name -> TState -> Name -> TState
  visitSucc graph v st w =
      case lookup w (index st) of
           Nothing =>
             let st' = strongConnect graph w st
                 wLow = fromMaybe 0 (lookup w (lowlink st'))
                 vLow = fromMaybe 0 (lookup v (lowlink st'))
             in MkTState (index st') (insert v (min vLow wLow) (lowlink st')) (onStack st') (stack st') (sccs st')
           Just wIdx =>
             if contains w (onStack st)
                then let vLow = fromMaybe 0 (lookup v (lowlink st))
                     in MkTState (index st) (insert v (min vLow wIdx) (lowlink st)) (onStack st) (stack st) (sccs st)
                else st

||| Each SCC is prepended as it's found, so a caller's own component
||| ends up *earlier* in the result than a callee's -- reverse the list
||| for callees-before-callers (bottom-up) processing order.
export
tarjanSCCs : Graph -> List (List Name)
tarjanSCCs graph =
    let allNames = map (\(n, _) => n) (SortedMap.toList graph)
        final = foldl (\st, v => if isJust (lookup v (index st)) then st else strongConnect graph v st) initTState allNames
    in sccs final

------------------------------------------------------------------------
-- Synthesising one merged group.

data FreshId : Type where

freshId : {auto r : Ref FreshId Int} -> Core Int
freshId = do i <- get FreshId; put FreshId (i + 1); pure i

freshName : {auto r : Ref FreshId Int} -> SortedSet Name -> Core Name
freshName existing = do
    i <- freshId
    let cand = MN "rc2_mutualLoop" i
    if contains cand existing then freshName existing else pure cand

||| Rewrite every tail-position call (self- or cross-member alike)
||| within an already-renamed member body into a tail call to the
||| merged function itself, carrying the target's tag and (padded)
||| arguments -- see the module note's ownership/invariant discussion
||| for why no extra drop/pad-related bookkeeping is needed here beyond
||| this substitution.
rewriteGroupTailCalls : Name -> Nat -> SortedMap Name Int -> RCExp -> RCExp
rewriteGroupTailCalls mergedName maxArity tagOf body =
    snd $ mapTailAppNames
        (\fc, n, args =>
            case lookup n tagOf of
                 Nothing => Nothing
                 Just t => Just $ RAppName fc Nothing mergedName $
                             RCConst (I64 (cast t)) :: args ++ replicate (maxArity `minus` length args) RCNull)
        body

buildGroup : {auto r : Ref FreshId Int}
          -> SortedSet Name
          -> SortedMap Name (List Int, RCExp)
          -> List Name
          -> Core (List (Name, RCDef))
buildGroup existingNames memberDefs groupNames = do
    -- Deterministic order (SortedSet.toList is sorted by `Ord Name`),
    -- so tag assignment doesn't depend on SCC-traversal order.
    let ordered = SortedSet.toList (SortedSet.fromList groupNames)
    members <- the (Core (List (Name, (List Int, RCExp)))) $
                 traverse (\n => case lookup n memberDefs of
                                      Just def => pure (n, def)
                                      Nothing => throw $ InternalError "[rc2] MutualLoop: SCC member not found") ordered
    let maxArity : Nat
        maxArity = foldl (\acc, (_, (args, _)) => max acc (length args)) 0 members
    let memberNames : List Name
        memberNames = map (\(n, _) => n) members
    let tagList : List Int
        tagList = map (\i => the Int (cast i)) [0 .. length members `minus` 1]
    let tagOf : SortedMap Name Int
        tagOf = SortedMap.fromList (zip memberNames tagList)
    mergedName <- freshName existingNames
    tagId <- freshId
    slotIds <- traverse (const freshId) (replicate maxArity ())
    alts <- traverse (\(name_i, (args_i, body_i)) => do
                let internalIds = collectBoundIds body_i
                freshInternal <- traverse (const freshId) internalIds
                let ren : Renaming = SortedMap.fromList (zip args_i slotIds ++ zip internalIds freshInternal)
                let renamedBody = renameRCExp ren body_i
                let tag_i = fromMaybe 0 (lookup name_i tagOf)
                pure $ MkRConstAlt (I64 (cast tag_i)) (rewriteGroupTailCalls mergedName maxArity tagOf renamedBody))
              members
    let mergedBody = RConstCase EmptyFC (RCLoc tagId) alts
                        (Just (RCrash EmptyFC "[rc2] internal: MutualLoop tag dispatch fell through"))
    let mergedDef = MkRCFun (map (\i => (i, RBoxed)) (tagId :: slotIds)) RBoxed mergedBody
    let wrappers = map (\(name_i, (args_i, _)) =>
                      let tag_i = fromMaybe 0 (lookup name_i tagOf)
                          padded = map RCLoc args_i ++ replicate (maxArity `minus` length args_i) RCNull
                      in (name_i, MkRCFun (map (\i => (i, RBoxed)) args_i) RBoxed
                            (RAppName EmptyFC Nothing mergedName (RCConst (I64 (cast tag_i)) :: padded))))
                    members
    pure ((mergedName, mergedDef) :: wrappers)

buildGraph : SortedMap Name (List Int, RCExp) -> Graph
buildGraph memberDefs =
    let allNames = SortedSet.fromList (map (\(n, _) => n) (SortedMap.toList memberDefs))
    in fromList $ map (\(n, (_, body)) =>
           (n, SortedSet.fromList (filter (\t => contains t allNames) (SortedSet.toList (tailCallTargets body)))))
         (SortedMap.toList memberDefs)

||| Whole-program pass: finds every group (size >= 2) of mutually
||| tail-recursive functions and replaces them with one synthesised
||| merged function plus a thin per-member wrapper each -- see the
||| module note for the full design. Definitions this pass doesn't
||| touch (everything outside a size->=2 group -- including ordinary,
||| possibly self-recursive, functions, and every non-`MkRCFun` def)
||| pass through completely unchanged.
export
applyMutualLoop : List (Name, RCDef) -> Core (List (Name, RCDef))
applyMutualLoop defs = do
    _ <- newRef FreshId 0
    let memberDefs = SortedMap.fromList $ mapMaybe
            (\(n, d) => case d of
                             MkRCFun args _ body => Just (n, (map fst args, body))
                             _ => Nothing)
            defs
    let graph = buildGraph memberDefs
    let groups = filter (\g => length g >= 2) (tarjanSCCs graph)
    let existingNames = SortedSet.fromList (map (\(n, _) => n) defs)
    newDefs <- concat <$> traverse (buildGroup existingNames memberDefs) groups
    let mergedMemberNames = SortedSet.fromList (concat groups)
    let untouched = filter (\(n, _) => not (contains n mergedMemberNames)) defs
    pure (untouched ++ newDefs)
