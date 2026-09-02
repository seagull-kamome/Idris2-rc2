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

%default covering

||| Every `Name` `e` might call directly (`RAppName`/`RAppNameRep`), or
||| reference as a first-class value to build a closure over
||| (`RUnderApp`) -- i.e. every `Name` reachability needs to follow to
||| decide whether some *other* definition stays live because of `e`.
|||
||| Deliberately NOT `Compiler.RC2.RCExp.freeLocalsR`/`countUsesR`/
||| `usedConstructorsR`: all three have their own `_ = empty` catch-all
||| and were written for narrower, earlier-pipeline purposes (free-
||| variable/use-count analysis in `Compiler.RC2.RC`, a local heuristic
||| in `Compiler.RC2.Reuse`) -- none of them descend into `RLoop`'s body
||| or know about `RAppNameRep`/`RAppFFIInline`, all of which only exist
||| this late in the pipeline (`Compiler.RC2.Loop`/`DualABI`). This
||| walker is exhaustive over every `RCExp` constructor precisely
||| because it has to be, running after every one of them exists.
|||
||| `RCon`'s own `Name` (a constructor, not a `defs` entry) and
||| `RExtPrim`'s `Name` (one of a fixed whitelist of compiler-known
||| primitive selectors -- see `Compiler.RC2.Emit`'s own `emitRC`
||| `RExtPrim` case -- never a `defs` lookup either) are both
||| deliberately excluded. `RAppFFIInline` carries no `Name` at all --
||| its target is a literal C symbol spliced from its own `ccs` field,
||| independent of `defs` entirely (see this module's own header note
||| on why that independence means `MkRCForeign` isn't in scope here).
export
usedFunctionNamesR : RCExp -> SortedSet Name
usedFunctionNamesR (RAppName _ _ n _) = singleton n
usedFunctionNamesR (RAppNameRep _ n _ _ _ _) = singleton n
usedFunctionNamesR (RUnderApp _ n _ _) = singleton n
usedFunctionNamesR (RAppFFIInline _ _ _ _ _ _) = empty
usedFunctionNamesR (RLet _ _ _ value body) = union (usedFunctionNamesR value) (usedFunctionNamesR body)
usedFunctionNamesR (RCmpCase _ _ _ _ t f) = union (usedFunctionNamesR t) (usedFunctionNamesR f)
usedFunctionNamesR (RConCase _ _ alts mDef) =
    let altsUsed = map (\(MkRConAlt _ _ _ _ body) => usedFunctionNamesR body) alts
    in concat (maybe altsUsed (\d => usedFunctionNamesR d :: altsUsed) mDef)
usedFunctionNamesR (RConstCase _ _ alts mDef) =
    let altsUsed = map (\(MkRConstAlt _ body) => usedFunctionNamesR body) alts
    in concat (maybe altsUsed (\d => usedFunctionNamesR d :: altsUsed) mDef)
usedFunctionNamesR (RDup _ _ body) = usedFunctionNamesR body
usedFunctionNamesR (RDrop _ _ body) = usedFunctionNamesR body
usedFunctionNamesR (RFree _ _ body) = usedFunctionNamesR body
usedFunctionNamesR (RReleaseReuse _ _ body) = usedFunctionNamesR body
usedFunctionNamesR (RReuseOffer _ _ _ _ body) = usedFunctionNamesR body
usedFunctionNamesR (RLoop _ _ _ _ body) = usedFunctionNamesR body
usedFunctionNamesR _ = empty

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
