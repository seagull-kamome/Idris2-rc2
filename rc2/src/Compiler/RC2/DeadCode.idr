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
        keep : (Name, RCDef) -> Bool
        keep (n, MkRCFun _ _ _ _) = contains n reachable
        keep (_, MkRCForeign _ _ _) = True
        keep (_, MkRCCon _ _ _) = True
        keep (_, MkRCError _) = True
    in filter keep defs
