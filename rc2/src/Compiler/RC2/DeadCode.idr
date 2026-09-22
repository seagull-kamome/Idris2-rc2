module Compiler.RC2.DeadCode

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Whole-program mark-and-sweep dead-code elimination, run as
-- `toRCDefs`'s own final stage, right before `Emit.generateCSourceFile`
-- consumes the same list. See `rc2/doc/dead-code-elim.md`'s
-- "Motivation" for why upstream's own reachability analysis (fixed
-- before any rc2 pass runs) can leave a definition genuinely dead only
-- after `Inline`/`DualABI` rewrite it (confirmed via
-- `rc2/tests/Test51DeadCodeInline.idr`), and its "Scope" section for
-- why only `MkRCFun` is ever pruned here -- `MkRCForeign` structurally
-- can't actually lose every caller via `Inline`/`DualABI` alone (a
-- first attempt at tracking it anyway never removed anything in
-- practice); `MkRCCon`/`MkRCError` simply aren't a currently-observed
-- source of dead code.

import Compiler.RC2.RCExp

import Core.Name

import Data.SortedMap
import Data.SortedSet
import Data.Vect

%default covering

||| Every `defs`-keyed function `Name` reachability follows from a def
||| -- a direct call (`RAppName`/`RAppNameRep`), a closure-building
||| reference (`RUnderApp`), or a `ConstFold`-folded closure
||| (`RCConstClosure`). Just the `Name` callbacks of `RCExp.idr`'s own
||| exhaustive `foldRCNamesD`, so a new `RCExp` constructor forces one
||| update there, not one here too. `RCon`/`RCConstCon`'s own `Name` (a
||| *constructor*, a different namespace from `defs`'s function-name
||| keys), `RExtPrim`'s `Name` (a fixed primitive whitelist), and
||| `RAppFFIInline` (no `Name` at all) are deliberately left out.
usedFunctionNamesD : RCDef -> SortedSet Name
usedFunctionNamesD =
    foldRCNamesD $ { onAppName      := \n, _ => singleton n
                   , onAppNameRep   := singleton
                   , onUnderApp     := singleton
                   , onConstClosure := singleton
                   } noRCNames

||| Standard worklist mark phase (`doc/dead-code-elim.md`'s "The sweep:
||| `pruneDeadDefs`"): `seen` starts as `roots` and grows by following
||| `usedFunctionNamesD` transitively -- a single pass suffices for the
||| whole transitive closure, no fixpoint loop needed.
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

||| Per-name `usedFunctionNamesD`, for a caller that prunes the same
||| program repeatedly and knows which definitions actually changed
||| since last time -- see `pruneDeadDefsCached`.
public export
RefCache : Type
RefCache = SortedMap Name (SortedSet Name)

||| `usedFunctionNamesD d` for `n`, reusing `cache`'s own entry unless
||| `dirty` says `n`'s body changed since that entry was made (or there
||| is no entry yet). Returns the entry alongside the cache it should
||| be remembered in.
refsOf : RefCache -> SortedSet Name -> Name -> RCDef -> (SortedSet Name, RefCache)
refsOf cache dirty n d =
    case lookup n cache of
         Just s => if contains n dirty then recompute else (s, cache)
         Nothing => recompute
  where
    recompute : (SortedSet Name, RefCache)
    recompute = let s = usedFunctionNamesD d in (s, insert n s cache)

||| `markReachable` threading a `RefCache` (see `refsOf`): identical
||| walk, except a definition whose body hasn't changed since it was
||| last visited doesn't get re-walked to re-derive the same reference
||| set. Only definitions the mark phase actually reaches ever enter the
||| cache, so an unreachable one costs nothing here either.
markReachableCached : RefCache -> SortedSet Name -> SortedMap Name RCDef -> List Name -> SortedSet Name -> (SortedSet Name, RefCache)
markReachableCached cache dirty table [] seen = (seen, cache)
markReachableCached cache dirty table (n :: ns) seen =
    case lookup n table of
         Nothing => markReachableCached cache dirty table ns seen
         Just d =>
             let (refs, cache') = refsOf cache dirty n d
                 new = filter (\r => not (contains r seen)) (Prelude.toList refs)
                 seen' = foldl (flip insert) seen new
             in markReachableCached cache' dirty table (new ++ ns) seen'

||| Whether a definition survives the sweep -- `MkRCFun` only when
||| `reachable` says so, everything else unconditionally (see this
||| module's own header note). Shared by both `pruneDeadDefs` and
||| `pruneDeadDefsCached`, which differ only in how `reachable` is
||| derived.
keepReachable : SortedSet Name -> (Name, RCDef) -> Bool
keepReachable reachable (n, MkRCFun _ _ _ _) = contains n reachable
keepReachable _ (_, MkRCForeign _ _ _) = True
keepReachable _ (_, MkRCCon _ _ _) = True
keepReachable _ (_, MkRCError _) = True

||| Drops every `MkRCFun` entry not transitively reachable from `roots`
||| (typically `main`'s well-known entry name plus any `%export`ed
||| names -- see `Compiler.RC2.RC2`'s own call site). `MkRCForeign`/
||| `MkRCCon`/`MkRCError` are always kept (see this module's own header
||| note). Order-preserving: `Compiler.RC2.Emit`'s own forward-
||| declaration order depends on it.
export
pruneDeadDefs : (roots : List Name) -> List (Name, RCDef) -> List (Name, RCDef)
pruneDeadDefs roots defs =
    let table = SortedMap.fromList defs
        reachable = markReachable table roots (SortedSet.fromList roots)
    in filter (keepReachable reachable) defs

||| `pruneDeadDefs` for a caller pruning the same program over and over
||| -- `Compiler.RC2.LateInline`'s own fixpoint loop, which re-prunes
||| every round -- reusing a `RefCache` across those calls so that only
||| definitions `dirty` names as actually rewritten since the last call
||| get their reference set re-derived. Everything else about the walk,
||| and its result, is identical to `pruneDeadDefs`. Returns the cache
||| to carry into the next call alongside the pruned list.
export
pruneDeadDefsCached : RefCache -> (dirty : SortedSet Name) -> (roots : List Name) -> List (Name, RCDef) -> (List (Name, RCDef), RefCache)
pruneDeadDefsCached cache dirty roots defs =
    let table = SortedMap.fromList defs
        (reachable, cache') = markReachableCached cache dirty table roots (SortedSet.fromList roots)
    in (filter (keepReachable reachable) defs, cache')
