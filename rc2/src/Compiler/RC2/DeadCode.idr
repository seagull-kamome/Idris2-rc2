module Compiler.RC2.DeadCode

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Whole-program mark-and-sweep dead-code elimination, run as `toRCDefs`'s
-- own final stage (`Compiler.RC2.RC2`) -- after `Compiler.RC2.Inline`,
-- `Compiler.RC2.Reuse`/`ConAltNative`, `Compiler.RC2.MutualLoop`/`Loop`/
-- `Sink`, and `Compiler.RC2.DualABI` have all run, on the exact
-- `List (Name, RCDef)` `Compiler.RC2.Emit.generateCSourceFile` is about
-- to consume.
--
-- Motivation: `getCompileData`'s own upstream reachability analysis
-- (`Compiler.Common`) fixes the *set* of definitions once, before any
-- of rc2's own passes run -- none of `toRCDefs`'s stages ever add to or
-- remove from that set, only rewrite bodies in place. But some of
-- those rewrites can make a definition genuinely unreachable *within
-- rc2's own final program*, in ways upstream's analysis (over the
-- original call graph) has no way to know about:
--
--   - `Compiler.RC2.Inline` splices an eligible callee's body into
--     *every* one of its own call sites (see that module's own "every
--     call site" eligibility rule) -- the original definition is left
--     behind with zero remaining callers (`rc2/tests/Test51DeadCode*`).
--     Nothing downstream of Inline is aware this happened, so
--     `Compiler.RC2.DualABI`'s Stage 3a will still cheerfully split
--     that now-dead definition into its own (equally dead) wrapper+
--     worker pair, same as any live function.
--   - `Compiler.RC2.DualABI`'s Stage 3a synthesizes an always-Boxed
--     wrapper alongside a native-calling-convention worker for any
--     eligible ordinary function; once Stage 4 rewrites that
--     function's own (necessarily non-tail, see that module's own doc)
--     call sites to call the worker directly, the wrapper itself can
--     end up with zero remaining callers if it had none to begin with
--     in tail position either (`rc2/tests/Test52DeadCode*`).
--
-- Confirmed real (not merely theoretical) via both of those tests --
-- see their own header comments and `rc2/doc/dead-code-elim.md`.
--
-- Deliberately narrow in scope: only `MkRCFun` is ever a candidate for
-- removal. See `rc2/doc/dead-code-elim.md`'s "Scope: `MkRCForeign`
-- deliberately excluded" section for why `%foreign` declarations
-- (`MkRCForeign`) are never pruned here: via `Inline`/`DualABI` alone a
-- surviving entry can't actually lose every caller, so a first attempt
-- at tracking this never removed anything in practice and was dropped.
-- `Compiler.RC2.ConstFold`'s own case-of-constant folding *can*
-- genuinely orphan one (discarding a whole branch, FFI call included --
-- see that same doc section and `TODO.md`'s own entry on it), left as a
-- known, rare, deliberately-unhandled gap rather than reviving that
-- tracking for it. `MkRCCon`/`MkRCError` are always kept too: pruning
-- constructor metadata needs to reason about pattern-match
-- alternatives (`RConAlt`/`RConstAlt`), which reference a
-- constructor's own `tag`/`arity` directly rather than through this
-- module's own `Name` graph, and isn't a currently-observed source of
-- dead code the way the two `MkRCFun` cases above are. A future
-- session revisiting either of these should treat it as a separate
-- investigation, not an extension of this pass as-is.

import Compiler.RC2.RCExp

import Core.Name

import Data.SortedMap
import Data.SortedSet
import Data.Vect

%default covering

||| Every `Name` an `RCLocal` itself embeds -- only ever non-empty for
||| `RCConstClosure` (a folded zero-filled closure over `n`, see
||| RCExp.idr's own doc comment) and, transitively, any `RCConstCon`
||| nesting one among its `args`. Specific to this pass's own
||| reachability concern (not a general-purpose `RCLocal` utility worth
||| exposing elsewhere): once `Compiler.RC2.ConstFold` can fold a
||| dictionary-shaped `RCon` (all fields zero-filled closures) into a
||| single `RCConstCon`, every one of those closures' own target names
||| becomes invisible to a walker that only looks at `RCExp` nodes --
||| `usedFunctionNamesR` below calls this on every `RCLocal`-typed field
||| it sees, in addition to its own existing `Name`-collection, so a
||| dictionary CAF's own immortal static keeps naming its methods live.
||| `RCConstCon`'s own `Name` field is a *constructor* name, a different
||| namespace from `defs`'s own function-name keys -- correctly excluded
||| here, only its `args` are ever recursed into.
usedFunctionNamesL : RCLocal -> SortedSet Name
usedFunctionNamesL (RCConstClosure n _)    = singleton n
usedFunctionNamesL (RCConstCon _ _ _ args) = concatMap usedFunctionNamesL args
usedFunctionNamesL (RCLoc _)               = empty
usedFunctionNamesL RCNull                  = empty
usedFunctionNamesL (RCConst _)             = empty
usedFunctionNamesL (RCEmptyCon {})         = empty

||| Every `Name` `e` might call directly (`RAppName`/`RAppNameRep`), or
||| reference as a first-class value to build a closure over
||| (`RUnderApp`, or a folded `RCConstClosure`/`RCConstCon` reached via
||| `usedFunctionNamesL` on any `RCLocal`-typed field) -- i.e. every
||| `Name` reachability needs to follow to decide whether some *other*
||| definition stays live because of `e`.
|||
||| Deliberately NOT `Compiler.RC2.RCExp.freeLocalsR`/`countUsesR`/
||| `usedConstructorsR`: all three have their own `_ = empty` catch-all
||| and were written for narrower, earlier-pipeline purposes (free-
||| variable/use-count analysis in `Compiler.RC2.RC`, a local heuristic
||| in `Compiler.RC2.Reuse`) -- none of them descend into `RLoop`'s body
||| or know about `RAppNameRep`/`RAppFFIInline`, all of which only exist
||| this late in the pipeline (`Compiler.RC2.Loop`/`DualABI`). This
||| walker is exhaustive over every `RCExp` constructor precisely
||| because it has to be, running after every one of them exists -- no
||| trailing catch-all, so a newly-added `RCExp` constructor is a
||| coverage error here rather than a silently-missed reachability edge
||| (exactly the gap that made a folded dictionary's own callees
||| invisible before `usedFunctionNamesL` existed).
|||
||| `RCon`'s own `Name` (a constructor, not a `defs` entry) and
||| `RExtPrim`'s `Name` (one of a fixed whitelist of compiler-known
||| primitive selectors -- see `Compiler.RC2.Emit`'s own `emitRC`
||| `RExtPrim` case -- never a `defs` lookup either) are both
||| deliberately excluded. `RAppFFIInline` carries no `Name` at all --
||| its target is a literal C symbol spliced from its own `ccs` field,
||| independent of `defs` entirely (see this module's own header note
||| on why that independence means `MkRCForeign` isn't in scope here) --
||| but its `args`/`postDrop` can still carry a folded `RCConstClosure`,
||| so those are still walked via `usedFunctionNamesL`.
export
usedFunctionNamesR : RCExp -> SortedSet Name
usedFunctionNamesR (RV _ l) = usedFunctionNamesL l
usedFunctionNamesR (RAppName _ _ n args) = insert n (concatMap usedFunctionNamesL args)
usedFunctionNamesR (RAppNameRep _ n _ _ postDrop args) =
    insert n (union (concatMap usedFunctionNamesL postDrop) (concatMap usedFunctionNamesL args))
usedFunctionNamesR (RAppFFIInline _ _ _ _ postDrop args) =
    union (concatMap usedFunctionNamesL postDrop) (concatMap usedFunctionNamesL args)
usedFunctionNamesR (RUnderApp _ n _ args) = insert n (concatMap usedFunctionNamesL args)
usedFunctionNamesR (RApp _ _ c a) = union (usedFunctionNamesL c) (usedFunctionNamesL a)
usedFunctionNamesR (RLet _ _ _ value body) = union (usedFunctionNamesR value) (usedFunctionNamesR body)
usedFunctionNamesR (RCon _ _ _ _ args reuseFrom) =
    union (concatMap usedFunctionNamesL args) (maybe empty usedFunctionNamesL reuseFrom)
usedFunctionNamesR (ROp _ _ _ args postDrop) =
    union (concatMap usedFunctionNamesL (toList args)) (concatMap usedFunctionNamesL postDrop)
usedFunctionNamesR (RExtPrim _ _ _ args postDrop) =
    union (concatMap usedFunctionNamesL args) (concatMap usedFunctionNamesL postDrop)
usedFunctionNamesR (RStructGet _ structVar _ _ postDrop) =
    union (usedFunctionNamesL structVar) (concatMap usedFunctionNamesL postDrop)
usedFunctionNamesR (RStructSet _ structVar _ _ value postDrop) =
    union (usedFunctionNamesL structVar)
          (union (usedFunctionNamesL value) (concatMap usedFunctionNamesL postDrop))
usedFunctionNamesR (RCmpCase _ _ args postDrop t f) =
    union (concatMap usedFunctionNamesL (toList args))
          (union (concatMap usedFunctionNamesL postDrop)
                 (union (usedFunctionNamesR t) (usedFunctionNamesR f)))
usedFunctionNamesR (RConCase _ sc alts mDef) =
    let altsUsed = map (\(MkRConAlt _ _ _ _ body) => usedFunctionNamesR body) alts
    in union (usedFunctionNamesL sc) (concat (maybe altsUsed (\d => usedFunctionNamesR d :: altsUsed) mDef))
usedFunctionNamesR (RConstCase _ sc alts mDef) =
    let altsUsed = map (\(MkRConstAlt _ body) => usedFunctionNamesR body) alts
    in union (usedFunctionNamesL sc) (concat (maybe altsUsed (\d => usedFunctionNamesR d :: altsUsed) mDef))
usedFunctionNamesR (RPrimVal _ _) = empty
usedFunctionNamesR (RErased _) = empty
usedFunctionNamesR (RCrash _ _) = empty
usedFunctionNamesR (RDup _ v _ body) = union (usedFunctionNamesL v) (usedFunctionNamesR body)
usedFunctionNamesR (RDrop _ vars body) = union (concatMap usedFunctionNamesL vars) (usedFunctionNamesR body)
usedFunctionNamesR (RFree _ v body) = union (usedFunctionNamesL v) (usedFunctionNamesR body)
usedFunctionNamesR (RReleaseReuse _ v body) = union (usedFunctionNamesL v) (usedFunctionNamesR body)
usedFunctionNamesR (RLoop _ _ initial prologueDrop body) =
    union (concatMap usedFunctionNamesL initial)
          (union (concatMap usedFunctionNamesL prologueDrop) (usedFunctionNamesR body))
usedFunctionNamesR (RLoopContinue _ args postDrop) =
    union (concatMap usedFunctionNamesL args) (concatMap usedFunctionNamesL postDrop)
usedFunctionNamesR (RReuseOffer _ sc dupOnShared dropOnUnique body) =
    union (usedFunctionNamesL sc)
          (union (concatMap usedFunctionNamesL dupOnShared)
                 (union (concatMap usedFunctionNamesL dropOnUnique) (usedFunctionNamesR body)))

||| Same idea as `usedFunctionNamesR`, lifted to a whole `RCDef`.
usedFunctionNamesD : RCDef -> SortedSet Name
usedFunctionNamesD (MkRCFun _ _ _ body) = usedFunctionNamesR body
usedFunctionNamesD (MkRCCon _ _ _) = empty
usedFunctionNamesD (MkRCForeign _ _ _) = empty
usedFunctionNamesD (MkRCError body) = usedFunctionNamesR body

||| Standard worklist mark phase: `seen` starts as `roots` and grows by
||| following `usedFunctionNamesD` transitively. A single pass suffices
||| for the *whole* transitive closure (no fixpoint loop needed) --
||| unlike a "repeatedly remove defs with zero direct callers, until
||| nothing changes" formulation, reachability-from-roots already
||| correctly excludes an entire dead chain (`A` unreachable, `B` called
||| only by `A`) in one traversal, since `B` is simply never enqueued.
markReachable : SortedMap Name RCDef -> List Name -> SortedSet Name -> SortedSet Name
markReachable table [] seen = seen
markReachable table (n :: ns) seen =
    case lookup n table of
         Nothing => markReachable table ns seen
         Just d =>
             let refs = Prelude.toList (usedFunctionNamesD d)
                 new = filter (\r => not (contains r seen)) refs
                 seen' = foldl (flip insert) seen new
             in markReachable table (new ++ ns) seen'

||| Drops every `MkRCFun` entry in `defs` not transitively reachable
||| from `roots` (typically `main`'s own well-known entry name plus any
||| `%export`ed names -- see `Compiler.RC2.RC2`'s own call site).
||| `MkRCForeign`/`MkRCCon`/`MkRCError` entries are always kept
||| regardless (see this module's own header note for why). Order-
||| preserving: `Compiler.RC2.Emit`'s own forward-declaration order
||| (`FunctionDefinitions`, built by consing in `defs`'s own order)
||| depends on it.
export
pruneDeadDefs : (roots : List Name) -> List (Name, RCDef) -> List (Name, RCDef)
pruneDeadDefs roots defs =
    let table = SortedMap.fromList defs
        reachable = markReachable table roots (SortedSet.fromList roots)
        keep : (Name, RCDef) -> Bool
        keep (n, MkRCFun _ _ _ _) = contains n reachable
        keep (_, MkRCForeign _ _ _) = True
        keep (_, MkRCCon _ _ _) = True
        keep (_, MkRCError _) = True
    in filter keep defs
