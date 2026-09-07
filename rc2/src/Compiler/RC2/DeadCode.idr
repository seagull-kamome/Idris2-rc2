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

||| Every `Name` an `RCLocal` itself embeds -- non-empty only for
||| `RCConstClosure`/`RCConstCon` (`Compiler.RC2.ConstFold`'s own
||| folded closures/constructors), whose own target names would
||| otherwise be invisible to a walker that only looks at `RCExp`
||| nodes. Not a general-purpose `RCLocal` utility -- specific to this
||| pass's own reachability concern. `RCConstCon`'s own `Name` field is
||| a *constructor* name, a different namespace from `defs`'s own
||| function-name keys -- correctly excluded, only its `args` recurse.
usedFunctionNamesL : RCLocal -> SortedSet Name
usedFunctionNamesL (RCConstClosure n _)    = singleton n
usedFunctionNamesL (RCConstCon _ _ _ args) = concatMap usedFunctionNamesL args
usedFunctionNamesL (RCLoc _)               = empty
usedFunctionNamesL RCNull                  = empty
usedFunctionNamesL (RCConst _)             = empty
usedFunctionNamesL (RCEmptyCon {})         = empty

||| Every `Name` reachability needs to follow from `e` -- direct calls
||| (`RAppName`/`RAppNameRep`) and closure-building references
||| (`RUnderApp`, or a folded closure/con reached via
||| `usedFunctionNamesL`). A fresh, exhaustive walker with no
||| catch-all, not a reuse of `RCExp.idr`'s own `freeLocalsR`/
||| `countUsesR`/`usedConstructorsR` -- see `doc/dead-code-elim.md`'s
||| "The walker: `usedFunctionNamesR`" for why those don't suffice.
||| `RCon`'s own `Name` (a constructor, not a `defs` entry),
||| `RExtPrim`'s `Name` (a fixed primitive whitelist), and
||| `RAppFFIInline` (carries no `Name` at all) are deliberately
||| excluded.
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
