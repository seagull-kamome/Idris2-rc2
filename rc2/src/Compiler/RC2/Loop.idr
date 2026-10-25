||| Self-tail-call loop conversion: wraps self-recursive calls in `RLoop`/`RLoopContinue`
||| to avoid trampoline dispatch, and promotes boxed parameters to native shadows
||| where usage is consistently native.
||| Scope: Self-tail-calls only (mutual recursion handled by MutualLoop).
||| See `rc2/doc/loop-conversion.md` for the full design and rationale.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Compiler.RC2.Loop

import Compiler.RC2.CalleeTable
import Compiler.RC2.NativeUse
import Compiler.RC2.RCExp
import Compiler.RC2.Rewrite
import Compiler.RC2.Types
import Compiler.RC2.Util

import Core.CompileExpr
import Core.Context

import Data.List1
import Data.SortedMap
import Data.SortedSet
import Data.Vect

%default covering

export
||| Fills in every `RLoopContinue`'s `postDrop` (the drop of a still-`Boxed`
||| argument feeding a native-shadowed loop param). `reps` is seeded from
||| `loopParams` and extended at each `RLet` and case-alt field.
||| Written here rather than reusing `DualABI`'s walk, which would be an import cycle.
fillLoopContinuePostDrop : List (Int, Rep) -> SortedMap Int Rep -> RCExp -> RCExp
fillLoopContinuePostDrop loopParams reps (RLet fc var rep value body) =
    RLet fc var rep value (fillLoopContinuePostDrop loopParams (insert var rep reps) body)
fillLoopContinuePostDrop loopParams reps (RCmpCase fc op args postDrop t f) =
    RCmpCase fc op args postDrop
      (fillLoopContinuePostDrop loopParams reps t) (fillLoopContinuePostDrop loopParams reps f)
fillLoopContinuePostDrop loopParams reps (RConCase fc sc alts mDef) =
    RConCase fc sc (map fillConAlt alts) (map (fillLoopContinuePostDrop loopParams reps) mDef)
  where
    fillConAlt : RConAlt -> RConAlt
    fillConAlt (MkRConAlt n ci tag as body) =
        MkRConAlt n ci tag as (fillLoopContinuePostDrop loopParams (foldl (\m, i => insert i RBoxed m) reps as) body)
fillLoopContinuePostDrop loopParams reps (RConstCase fc sc alts mDef) =
    RConstCase fc sc (map (\(MkRConstAlt c body) => MkRConstAlt c (fillLoopContinuePostDrop loopParams reps body)) alts)
      (map (fillLoopContinuePostDrop loopParams reps) mDef)
fillLoopContinuePostDrop loopParams reps (RDup fc v extra cont) = RDup fc v extra (fillLoopContinuePostDrop loopParams reps cont)
fillLoopContinuePostDrop loopParams reps (RDrop fc vs cont) = RDrop fc vs (fillLoopContinuePostDrop loopParams reps cont)
fillLoopContinuePostDrop loopParams reps (RFree fc v cont) = RFree fc v (fillLoopContinuePostDrop loopParams reps cont)
fillLoopContinuePostDrop loopParams reps (RReleaseReuse fc v cont) =
    RReleaseReuse fc v (fillLoopContinuePostDrop loopParams reps cont)
fillLoopContinuePostDrop loopParams reps (RReuseOffer fc sc dupOnShared dropOnUnique cont) =
    RReuseOffer fc sc dupOnShared dropOnUnique (fillLoopContinuePostDrop loopParams reps cont)
fillLoopContinuePostDrop loopParams reps (RLoopContinue fc args _) =
    let postDrop = mapMaybe (\((_, paramRep), arg) => case paramRep of
                                   RBoxed => Nothing
                                   _ => needsDrop arg) (zip loopParams args)
    in RLoopContinue fc args postDrop
  where
    needsDrop : RCLocal -> Maybe RCLocal
    needsDrop v@(RCLoc i) = case fromMaybe RBoxed (lookup i reps) of
                                  RBoxed => Just v
                                  _ => Nothing
    needsDrop _ = Nothing
fillLoopContinuePostDrop _ _ e = e

||| Every `RLoopContinue` reachable in `e`, collecting each one's own
||| `args` list -- same tree shape `fillLoopContinuePostDrop` itself
||| walks (its own doc comment's "no nested `RLoop`" reasoning applies
||| here unchanged), just collecting instead of rewriting.
collectContinueArgs : RCExp -> List (List RCLocal)
collectContinueArgs (RLet _ _ _ _ body) = collectContinueArgs body
collectContinueArgs (RCmpCase _ _ _ _ t f) = collectContinueArgs t ++ collectContinueArgs f
collectContinueArgs (RConCase _ _ alts mDef) =
    concatMap (\(MkRConAlt _ _ _ _ body) => collectContinueArgs body) alts
      ++ maybe [] collectContinueArgs mDef
collectContinueArgs (RConstCase _ _ alts mDef) =
    concatMap (\(MkRConstAlt _ body) => collectContinueArgs body) alts
      ++ maybe [] collectContinueArgs mDef
collectContinueArgs (RDup _ _ _ cont) = collectContinueArgs cont
collectContinueArgs (RDrop _ _ cont) = collectContinueArgs cont
collectContinueArgs (RFree _ _ cont) = collectContinueArgs cont
collectContinueArgs (RReleaseReuse _ _ cont) = collectContinueArgs cont
collectContinueArgs (RReuseOffer _ _ _ _ cont) = collectContinueArgs cont
collectContinueArgs (RLoopContinue _ args _) = [args]
collectContinueArgs _ = []

||| Every loop param's own id (a shadow id where native-shadowed, the
||| original top-level parameter id otherwise) that *every* collected
||| `RLoopContinue` supplies completely unchanged (`RCLoc` of that same
||| id, at that same position) -- a param that never actually varies
||| across an iteration, so it has no business being loop-carried at
||| all. See `applyLoop`'s own doc comment for what happens to one of
||| these next.
invariantLoopParamIds : List (Int, Rep) -> List (List RCLocal) -> SortedSet Int
invariantLoopParamIds fullLoopParams continues =
    let start : List (Int, Bool)
        start = map (\(p, _) => (p, True)) fullLoopParams
        settled : List (Int, Bool)
        settled = foldl (\acc, cargs => zipWith (\(p, inv), arg => (p, inv && arg == RCLoc p)) acc cargs)
                         start continues
    in fromList $ map fst $ filter snd settled

||| Drops every `inv`-listed position's own argument from each
||| `RLoopContinue` reachable in `e`, keyed positionally against
||| `fullLoopParams` (the *un*-filtered param list every
||| `RLoopContinue`'s own `args` is still aligned against at this
||| point) -- same tree shape `fillLoopContinuePostDrop` walks.
||| `postDrop` itself is untouched: an invariant position is never a
||| source of one (it's never fed by a fresh Boxed computation -- by
||| definition it's the very same already-native-or-Boxed local every
||| time).
elideInvariantContinueArgs : SortedSet Int -> List (Int, Rep) -> RCExp -> RCExp
elideInvariantContinueArgs inv fullLoopParams (RLet fc var rep value body) =
    RLet fc var rep value (elideInvariantContinueArgs inv fullLoopParams body)
elideInvariantContinueArgs inv fullLoopParams (RCmpCase fc op args postDrop t f) =
    RCmpCase fc op args postDrop
      (elideInvariantContinueArgs inv fullLoopParams t) (elideInvariantContinueArgs inv fullLoopParams f)
elideInvariantContinueArgs inv fullLoopParams (RConCase fc sc alts mDef) =
    RConCase fc sc (map elideAlt alts) (map (elideInvariantContinueArgs inv fullLoopParams) mDef)
  where
    elideAlt : RConAlt -> RConAlt
    elideAlt (MkRConAlt n ci tag as body) = MkRConAlt n ci tag as (elideInvariantContinueArgs inv fullLoopParams body)
elideInvariantContinueArgs inv fullLoopParams (RConstCase fc sc alts mDef) =
    RConstCase fc sc (map (\(MkRConstAlt c body) => MkRConstAlt c (elideInvariantContinueArgs inv fullLoopParams body)) alts)
      (map (elideInvariantContinueArgs inv fullLoopParams) mDef)
elideInvariantContinueArgs inv fullLoopParams (RDup fc v extra cont) = RDup fc v extra (elideInvariantContinueArgs inv fullLoopParams cont)
elideInvariantContinueArgs inv fullLoopParams (RDrop fc vs cont) = RDrop fc vs (elideInvariantContinueArgs inv fullLoopParams cont)
elideInvariantContinueArgs inv fullLoopParams (RFree fc v cont) = RFree fc v (elideInvariantContinueArgs inv fullLoopParams cont)
elideInvariantContinueArgs inv fullLoopParams (RReleaseReuse fc v cont) =
    RReleaseReuse fc v (elideInvariantContinueArgs inv fullLoopParams cont)
elideInvariantContinueArgs inv fullLoopParams (RReuseOffer fc sc dupOnShared dropOnUnique cont) =
    RReuseOffer fc sc dupOnShared dropOnUnique (elideInvariantContinueArgs inv fullLoopParams cont)
elideInvariantContinueArgs inv fullLoopParams (RLoopContinue fc args postDrop) =
    RLoopContinue fc (map snd $ filter (\((p, _), _) => not (contains p inv)) (zip fullLoopParams args)) postDrop
elideInvariantContinueArgs _ _ e = e

||| Whether `RCLocal` `v` reads something loop-*variant* (a member of
||| `variant`) -- the single question `isInvariantExpr`'s own operand
||| scan asks of every argument. A constant/`NULL`/tagged-empty-con
||| local is always invariant (it's not an `RCLoc` at all).
noneVariant : SortedSet Int -> RCLocal -> Bool
noneVariant variant (RCLoc i) = not (contains i variant)
noneVariant _ _ = True

||| Whether running the operation unconditionally, ahead of the loop,
||| is safe. An integer `Div`/`Mod` qualifies only with a literal
||| divisor that can neither trap (zero) nor overflow (`-1`, as in
||| `INT_MIN / -1`): hoisting runs it ahead of the guard that makes a
||| variable divisor safe. `Crash` never qualifies. Double division and
||| every other operation always do.
hoistableOp : PrimFn n -> List RCLocal -> Bool
hoistableOp (Div _) [_, RCConst c] = literalOk c
  where
    literalOk : Constant -> Bool
    literalOk (I x) = x /= 0 && x /= -1
    literalOk (I8 x) = x /= 0 && x /= -1
    literalOk (I16 x) = x /= 0 && x /= -1
    literalOk (I32 x) = x /= 0 && x /= -1
    literalOk (I64 x) = x /= 0 && x /= -1
    literalOk (BI x) = x /= 0 && x /= -1
    literalOk (B8 x) = x /= 0
    literalOk (B16 x) = x /= 0
    literalOk (B32 x) = x /= 0
    literalOk (B64 x) = x /= 0
    literalOk _ = False
hoistableOp (Mod ty) [x, d] = hoistableOp (Div ty) [x, d]
hoistableOp (Div DoubleType) _ = True
hoistableOp (Div _) _ = False
hoistableOp Crash _ = False
hoistableOp _ _ = True

||| Whether `e` (an `RLet` value, seen through leading `RDup`/`RDrop`/`RFree`/
||| `RReleaseReuse`) is an `ROp`/`RCon` reading only operands outside `variant`,
||| and passes the conservative exclusions (`postDrop`, `Div`/`Mod` divisor, `lazy`,
||| `reuseFrom`). The native-`Rep` requirement is checked by the caller,
||| `hoistInvariantPrefix`. See `rc2/doc/loop-conversion.md`'s "Loop-invariant expression hoisting".
isInvariantExpr : SortedSet Int -> RCExp -> Bool
isInvariantExpr variant (ROp _ Nothing fn args []) = hoistableOp fn (toList args) && all (noneVariant variant) (toList args)
isInvariantExpr variant (RCon _ _ _ _ args Nothing) = all (noneVariant variant) args
isInvariantExpr variant (RDup _ _ _ cont) = isInvariantExpr variant cont
isInvariantExpr variant (RDrop _ _ cont) = isInvariantExpr variant cont
isInvariantExpr variant (RFree _ _ cont) = isInvariantExpr variant cont
isInvariantExpr variant (RReleaseReuse _ _ cont) = isInvariantExpr variant cont
isInvariantExpr _ _ = False

||| Pulls every loop-invariant `RLet` binding out of `e`'s straight-line `RLet`
||| chain, recursing into every arm of each branch reached. Returns the hoisted
||| bindings (original relative order) and the remainder with them removed.
||| Only a `Native`/`RInlineNative` result may be hoisted: a hoisted `Boxed` value
||| leaves a stale `drop` in the arm that does not use it (double free).
||| See `rc2/doc/loop-conversion.md`'s "Loop-invariant expression hoisting".
hoistInvariantPrefix : SortedSet Int -> RCExp -> (List (Int, Rep, RCExp), RCExp)
hoistInvariantPrefix variant (RLet fc var rep value body) =
    if isNativeRep rep && isInvariantExpr variant value
       then let (hoisted, rest) = hoistInvariantPrefix variant body
            in ((var, rep, value) :: hoisted, rest)
       else let (hoisted, rest) = hoistInvariantPrefix (insert var variant) body
            in (hoisted, RLet fc var rep value rest)
hoistInvariantPrefix variant (RDup fc v extra cont) =
    let (hoisted, rest) = hoistInvariantPrefix variant cont in (hoisted, RDup fc v extra rest)
hoistInvariantPrefix variant (RDrop fc vs cont) =
    let (hoisted, rest) = hoistInvariantPrefix variant cont in (hoisted, RDrop fc vs rest)
hoistInvariantPrefix variant (RFree fc v cont) =
    let (hoisted, rest) = hoistInvariantPrefix variant cont in (hoisted, RFree fc v rest)
hoistInvariantPrefix variant (RReleaseReuse fc v cont) =
    let (hoisted, rest) = hoistInvariantPrefix variant cont in (hoisted, RReleaseReuse fc v rest)
hoistInvariantPrefix variant (RReuseOffer fc sc dupOnShared dropOnUnique cont) =
    let (hoisted, rest) = hoistInvariantPrefix variant cont in (hoisted, RReuseOffer fc sc dupOnShared dropOnUnique rest)
hoistInvariantPrefix variant (RCmpCase fc op args postDrop t f) =
    let (hoistedT, t') = hoistInvariantPrefix variant t
        (hoistedF, f') = hoistInvariantPrefix variant f
    in (hoistedT ++ hoistedF, RCmpCase fc op args postDrop t' f')
hoistInvariantPrefix variant (RConCase fc sc alts mDef) =
    let altResults = map (\(MkRConAlt name ci tag args body) =>
                             let (h, body') = hoistInvariantPrefix (union variant (fromList args)) body
                             in (h, MkRConAlt name ci tag args body')) alts
        defResult = map (hoistInvariantPrefix variant) mDef
    in (concatMap fst altResults ++ maybe [] fst defResult,
        RConCase fc sc (map snd altResults) (map snd defResult))
hoistInvariantPrefix variant (RConstCase fc sc alts mDef) =
    let altResults = map (\(MkRConstAlt c body) =>
                             let (h, body') = hoistInvariantPrefix variant body
                             in (h, MkRConstAlt c body')) alts
        defResult = map (hoistInvariantPrefix variant) mDef
    in (concatMap fst altResults ++ maybe [] fst defResult,
        RConstCase fc sc (map snd altResults) (map snd defResult))
hoistInvariantPrefix _ e = ([], e)

------------------------------------------------------------------------
-- Reuses a loop-invariant parameter's original Boxed value for a surviving
-- Boxed-context read instead of reboxing from the shadow. Every such read is
-- `dup`'d (`dupInvariantBoxed`) with one release after the loop: a move would
-- be a use-after-free on the next iteration.
-- See `rc2/doc/loop-conversion.md`'s "Reusing the original Boxed value for a surviving Boxed-context read".

||| Mirrors `Compiler.RC2.ConAltNative`'s own `renameOpArgsThrough`
||| exactly (itself mirroring this module's own `opNativeUsesThrough`)
||| -- re-declared here rather than exported across the module boundary:
||| once inside the `ROp`
||| that a native-`Rep` `RLet`'s own `value` peels down to (through
||| `RDup`/`RDrop`/`RFree`/`RReleaseReuse`/nested-`RLet`-`body`
||| wrapping), redirect `p`'s own occurrences in that `ROp`'s own
||| `args` to `sid`.
invariantOpArgsThrough : (p : Int) -> (sid : Int) -> RCExp -> RCExp
invariantOpArgsThrough p sid (ROp fc lazy op args postDrop) =
    ROp fc lazy op (map (\a => if a == RCLoc p then RCLoc sid else a) args) postDrop
invariantOpArgsThrough p sid (RDup fc v extra cont) = RDup fc v extra (invariantOpArgsThrough p sid cont)
invariantOpArgsThrough p sid (RDrop fc vs cont) = RDrop fc vs (invariantOpArgsThrough p sid cont)
invariantOpArgsThrough p sid (RFree fc v cont) = RFree fc v (invariantOpArgsThrough p sid cont)
invariantOpArgsThrough p sid (RReleaseReuse fc v cont) = RReleaseReuse fc v (invariantOpArgsThrough p sid cont)
invariantOpArgsThrough p sid (RLet fc var rep value body) = RLet fc var rep value (invariantOpArgsThrough p sid body)
invariantOpArgsThrough _ _ e = e

||| Mirrors `nativeArgTypes`'s own walk exactly (identical cases), but
||| rewrites the native-context occurrences it finds instead of
||| collecting their types. Every Boxed-context occurrence of `p` (an
||| `RCon`/`RAppName`/etc. operand -- anywhere `nativeArgTypes` itself
||| falls through to its own `_ = empty` case) is left completely
||| untouched; `dupInvariantBoxed` handles those next.
|||
||| The one addition *not* mirrored from `nativeArgTypes` (which never
||| looks at an `RLoopContinue` at all -- see its own doc comment):
||| `p`'s own occurrence in a continue's own `args`, at the position
||| this parameter still occupies before `elideInvariantContinueArgs`
||| (run later, after this) removes it. Must be redirected here too,
||| alongside every other occurrence -- see rc2/doc/loop-conversion.md's
||| "Bugs found and fixed" #6 for the spurious-drop double-free this
||| left unfixed causes in `fillLoopContinuePostDrop`'s own lookup.
markInvariantNative : (p : Int) -> (sid : Int) -> RCExp -> RCExp
markInvariantNative p sid (RLet fc var rep value body) =
    let value' = case rep of
                      RBoxed => value
                      _ => invariantOpArgsThrough p sid value
    in RLet fc var rep (markInvariantNative p sid value') (markInvariantNative p sid body)
markInvariantNative p sid (RCmpCase fc op args postDrop t f) =
    RCmpCase fc op (map (\a => if a == RCLoc p then RCLoc sid else a) args) postDrop
             (markInvariantNative p sid t) (markInvariantNative p sid f)
markInvariantNative p sid (RLoopContinue fc args postDrop) =
    RLoopContinue fc (map (\a => if a == RCLoc p then RCLoc sid else a) args) postDrop
markInvariantNative p sid (RDup fc v extra cont) = RDup fc v extra (markInvariantNative p sid cont)
markInvariantNative p sid (RDrop fc vs cont) = RDrop fc vs (markInvariantNative p sid cont)
markInvariantNative p sid (RFree fc v cont) = RFree fc v (markInvariantNative p sid cont)
markInvariantNative p sid (RReleaseReuse fc v cont) = RReleaseReuse fc v (markInvariantNative p sid cont)
markInvariantNative p sid (RReuseOffer fc sc dupOnShared dropOnUnique cont) =
    RReuseOffer fc sc dupOnShared dropOnUnique (markInvariantNative p sid cont)
markInvariantNative p sid (RConCase fc sc alts mDef) =
    RConCase fc sc (map (\(MkRConAlt n ci tag as body) => MkRConAlt n ci tag as (markInvariantNative p sid body)) alts)
                    (map (markInvariantNative p sid) mDef)
markInvariantNative p sid (RConstCase fc sc alts mDef) =
    RConstCase fc sc (map (\(MkRConstAlt c body) => MkRConstAlt c (markInvariantNative p sid body)) alts)
                      (map (markInvariantNative p sid) mDef)
markInvariantNative _ _ e = e

||| Whether `p` is referenced anywhere in `e` -- `RCExp.idr`'s own
||| `countUsesR`, specialised to a yes/no question, but with `RLoop`/
||| `RLoopContinue` cases added. `countUsesR` itself was designed for
||| Phase 2 (`RC.idr`'s own `annotate`), which never sees an `RLoop` at
||| all (`Compiler.RC2.Loop` produces its first one strictly after
||| Phase 2 runs) -- its own catch-all `_ = 0` silently undercounts a
||| tree that already contains one, exactly the shape
||| `applyLoop`'s own `wrapInvariantShadows` hands it below (`acc`
||| there is, almost always, the `RLoop` itself, or an `RLet` wrapping
||| one). See rc2/doc/loop-conversion.md's "Loop-invariant parameter
||| elision" section for the crash a local copy of `countUsesR` without
||| these two cases caused (Test110Loop/LoopInvariantParam.idr).
|||
||| A yes/no question needs only the *first* occurrence, not an exact
||| tally -- `existsInvariantUse` short-circuits on it (each `if`
||| below never evaluates its own `else` once `then` already fired,
||| and `any`'s own short-circuiting search covers the list-argument
||| cases the same way), unlike summing a `Nat` count via `+`/`sum`
||| (always strict in both operands) then comparing `> 0` at the very
||| end.
usesInvariant : Int -> RCExp -> Bool
usesInvariant p e = existsInvariantUse e
  where
    existsInvariantUse : RCExp -> Bool
    existsInvariantUse (RV _ v) = v == RCLoc p
    existsInvariantUse (RAppName _ _ _ args) = any (== RCLoc p) args
    existsInvariantUse (RUnderApp _ _ _ args) = any (== RCLoc p) args
    existsInvariantUse (RDelay _ _ _ caps) = any (== RCLoc p) caps
    existsInvariantUse (RApp _ _ c args) = c == RCLoc p || any (== RCLoc p) args
    existsInvariantUse (RLet _ _ _ value body) =
        existsInvariantUse value || existsInvariantUse body
    existsInvariantUse (RCon _ _ _ _ args _) = any (== RCLoc p) args
    existsInvariantUse (ROp _ _ _ args _) = any (== RCLoc p) (toList args)
    existsInvariantUse (RExtPrim _ _ _ args _) = any (== RCLoc p) args
    existsInvariantUse (RStructGet _ structVar _ _) = structVar == RCLoc p
    existsInvariantUse (RForce _ _ v _) = v == RCLoc p
    existsInvariantUse (RStructSet _ structVar _ value _) =
        structVar == RCLoc p || value == RCLoc p
    existsInvariantUse (RFill _ cell _ value _) = cell == RCLoc p || value == RCLoc p
    existsInvariantUse (RCmpCase _ _ args _ t f) =
        any (== RCLoc p) (toList args) || existsInvariantUse t || existsInvariantUse f
    existsInvariantUse (RConCase _ sc alts mDef) =
        sc == RCLoc p || any (\(MkRConAlt _ _ _ _ body) => existsInvariantUse body) alts || maybe False existsInvariantUse mDef
    existsInvariantUse (RConstCase _ sc alts mDef) =
        sc == RCLoc p || any (\(MkRConstAlt _ body) => existsInvariantUse body) alts || maybe False existsInvariantUse mDef
    existsInvariantUse (RDup _ v _ body) =
        v == RCLoc p || existsInvariantUse body
    existsInvariantUse (RDrop _ vars body) =
        any (== RCLoc p) vars || existsInvariantUse body
    existsInvariantUse (RFree _ v body) =
        v == RCLoc p || existsInvariantUse body
    existsInvariantUse (RReleaseReuse _ v body) =
        v == RCLoc p || existsInvariantUse body
    existsInvariantUse (RReuseOffer _ sc dupOnShared dropOnUnique body) =
        sc == RCLoc p || any (== RCLoc p) dupOnShared || any (== RCLoc p) dropOnUnique || existsInvariantUse body
    existsInvariantUse (RLoop _ _ initial prologueDrop body) =
        any (== RCLoc p) initial || any (== RCLoc p) prologueDrop || existsInvariantUse body
    existsInvariantUse (RLoopContinue _ args postDrop) =
        any (== RCLoc p) args || any (== RCLoc p) postDrop
    existsInvariantUse _ = False

||| How many `RDup`s an operand list needs for `p`'s own occurrences in
||| it -- unlike `RC.idr`'s own `splitBorrows`, never consults an
||| `owned` state: *every* occurrence gets its own `dup`, unconditionally
||| (see this section's own header note for why -- a loop's own
||| continue path can re-execute the very same occurrence once per
||| iteration, so there's no single "first" occurrence whose own move
||| would ever be safe).
countInvariantDups : (p : Int) -> List RCLocal -> Nat
countInvariantDups p args = length (filter (== RCLoc p) args)

||| Nest `n` `RDup`s for `p` around `e`.
wrapInvariantDups : FC -> Int -> Nat -> RCExp -> RCExp
wrapInvariantDups fc p Z e = e
wrapInvariantDups fc p (S k) e = RDup fc (RCLoc p) 0 (wrapInvariantDups fc p k e)

||| Unconditionally `dup`s every surviving Boxed-context occurrence of
||| `p` in `e` (already known, by construction, to contain no
||| native-context ones -- those were redirected away by
||| `markInvariantNative` before this ever runs). Never touches any
||| other local's own ownership node -- every case below only ever
||| inspects or rewrites `p`'s own occurrences, the same discipline
||| `ConAltNative.idr`'s own `reannotateFieldOwnership` follows (though
||| that function tracks `owned` state to decide move-vs-dup; this one
||| doesn't need to, see this section's own header note).
dupInvariantBoxed : (p : Int) -> RCExp -> RCExp
dupInvariantBoxed p (RV fc v) =
    if v == RCLoc p then RDup fc v 0 (RV fc v) else RV fc v
dupInvariantBoxed p (RAppName fc lazy n args) =
    wrapInvariantDups fc p (countInvariantDups p args) (RAppName fc lazy n args)
dupInvariantBoxed p (RUnderApp fc n missing args) =
    wrapInvariantDups fc p (countInvariantDups p args) (RUnderApp fc n missing args)
dupInvariantBoxed p (RDelay fc lr n caps) =
    wrapInvariantDups fc p (countInvariantDups p caps) (RDelay fc lr n caps)
dupInvariantBoxed p (RApp fc lazy c args) =
    wrapInvariantDups fc p (countInvariantDups p (c :: forget args)) (RApp fc lazy c args)
dupInvariantBoxed p (RLet fc var rep value body) =
    RLet fc var rep (dupInvariantBoxed p value) (dupInvariantBoxed p body)
dupInvariantBoxed p (RCon fc n ci tag args reuseFrom) =
    wrapInvariantDups fc p (countInvariantDups p args) (RCon fc n ci tag args reuseFrom)
dupInvariantBoxed p (ROp fc lazy op args postDrop) =
    -- Every occurrence needs its own drop once the op is done reading
    -- it, dup'd or not (RC.idr's own `boxedOperands` doesn't consult
    -- ownership either, for the same reason) -- reached only when the
    -- enclosing `RLet`'s own `Rep` is `RBoxed` (a `Native`/`RInlineNative`
    -- one's own `value` was already fully redirected by
    -- `markInvariantNative`, leaving no occurrence of `p` here for this
    -- case to ever see).
    let argsList = toList args
        occ = countInvariantDups p argsList
    in wrapInvariantDups fc p occ (ROp fc lazy op args (postDrop ++ List.replicate occ (RCLoc p)))
-- Mirrors the ROp case immediately above exactly, primitive-agnostic
-- (RC.idr's own annotate RExtPrim case follows the same contract
-- as ROp's own -- see doc/c-struct-support.md's "Why a dedicated node").
dupInvariantBoxed p (RExtPrim fc lazy nm args postDrop) =
    let occ = countInvariantDups p args
    in wrapInvariantDups fc p occ (RExtPrim fc lazy nm args (postDrop ++ List.replicate occ (RCLoc p)))
dupInvariantBoxed p (RStructGet fc structVar sf postDrop) =
    wrapInvariantDups fc p (countInvariantDups p [structVar]) (RStructGet fc structVar sf postDrop)
dupInvariantBoxed p (RForce fc lr v postDrop) =
    wrapInvariantDups fc p (countInvariantDups p [v]) (RForce fc lr v postDrop)
dupInvariantBoxed p (RStructSet fc structVar sf value postDrop) =
    wrapInvariantDups fc p (countInvariantDups p [structVar, value]) (RStructSet fc structVar sf value postDrop)
dupInvariantBoxed p (RFill fc cell k value postDrop) =
    wrapInvariantDups fc p (countInvariantDups p [cell, value]) (RFill fc cell k value postDrop)
dupInvariantBoxed p (RCmpCase fc op args postDrop t f) =
    -- markInvariantNative already redirected every native-context
    -- occurrence in `args` to the shadow id -- args is left untouched
    -- here (p genuinely shouldn't still appear in it).
    RCmpCase fc op args postDrop (dupInvariantBoxed p t) (dupInvariantBoxed p f)
dupInvariantBoxed p (RConCase fc sc alts mDef) =
    wrapInvariantDups fc p (countInvariantDups p [sc])
      (RConCase fc sc (map (\(MkRConAlt n ci tag as body) => MkRConAlt n ci tag as (dupInvariantBoxed p body)) alts)
                       (map (dupInvariantBoxed p) mDef))
dupInvariantBoxed p (RConstCase fc sc alts mDef) =
    wrapInvariantDups fc p (countInvariantDups p [sc])
      (RConstCase fc sc (map (\(MkRConstAlt c body) => MkRConstAlt c (dupInvariantBoxed p body)) alts)
                         (map (dupInvariantBoxed p) mDef))
dupInvariantBoxed p (RDup fc v extra cont) = RDup fc v extra (dupInvariantBoxed p cont)
dupInvariantBoxed p (RDrop fc vs cont) = RDrop fc vs (dupInvariantBoxed p cont)
dupInvariantBoxed p (RFree fc v cont) = RFree fc v (dupInvariantBoxed p cont)
dupInvariantBoxed p (RReleaseReuse fc v cont) = RReleaseReuse fc v (dupInvariantBoxed p cont)
dupInvariantBoxed p (RReuseOffer fc sc dupOnShared dropOnUnique cont) = RReuseOffer fc sc dupOnShared dropOnUnique (dupInvariantBoxed p cont)
-- `acc` here is `applyLoop`'s own `withHoistedExprs` -- almost always
-- an `RLoop` itself (or an `RLet` chain wrapping one), *not* a tree
-- where one can't appear -- so this case is very much live, unlike the
-- analogous case in `Compiler.RC2.ConAltNative`'s own
-- `reannotateFieldOwnership` (which never sees one, since that pass
-- runs strictly before this one). `p` is never expected to appear in
-- `initial`/`prologueDrop` in practice (an invariant parameter's own
-- continue-arg position is elided by `elideInvariantContinueArgs`,
-- which runs after this, and `initial`/`prologueDrop` are themselves
-- built from `argIds` reads that `markInvariantNative` already
-- redirected to the shadow id wherever `p` itself was invariant) --
-- `wrapInvariantDups` on them is defensive totality, not a load-bearing
-- path.
dupInvariantBoxed p (RLoop fc loopParams initial prologueDrop body) =
    wrapInvariantDups fc p (countInvariantDups p initial + countInvariantDups p prologueDrop)
      (RLoop fc loopParams initial prologueDrop (dupInvariantBoxed p body))
-- Same defensive reasoning as `RLoop` above -- `markInvariantNative`
-- already redirected `p`'s own occurrence in a continue's own `args`
-- to the shadow id, so this case is never expected to actually fire.
dupInvariantBoxed p (RLoopContinue fc args postDrop) =
    wrapInvariantDups fc p (countInvariantDups p args) (RLoopContinue fc args postDrop)
-- RPrimVal/RErased/RCrash carry no locals; RAppNameRep never actually
-- appears here in practice -- this whole pass runs strictly before
-- Compiler.RC2.DualABI ever produces one.
dupInvariantBoxed _ e = e

||| Self-tail-call loop conversion of one definition, given its own `Name`;
||| wraps the rewritten body in one `RLoop` when a self-tail-call exists.
||| `nextId0` is the fresh-id counter start, returned advanced alongside the def.
||| `calleeTable` extends native-shadow eligibility of a loop-variant parameter
||| to a call argument; invariant parameters stay excluded because
||| `markInvariantNative` has no `RAppName` case.
||| See `rc2/doc/loop-conversion.md`'s "`applyLoop` -- the wrapping decision" and "Known limitation".
applyLoopFromId : (nextId0 : Int) -> CalleeTable -> (noPromote : SortedSet Int) -> Name -> RCDef -> (Int, RCDef)
applyLoopFromId nextId0 calleeTable noPromote self (MkRCFun args retRep isWorker body) =
    let argIds = map fst args
        (_, found, body') = mapTailAppNames (\fc, n, args' => if n == self then Just (RLoopContinue fc args' []) else Nothing) body
    in if not found
          then (nextId0, MkRCFun args retRep isWorker body')
          else
              let -- Decided *before* any renaming touches body' at all
                  -- (see this module's own header note on
                  -- `invariantOpArgsThrough`/`markInvariantNative`/
                  -- `dupInvariantBoxed` above): whether a given continue
                  -- supplies a parameter's own id unchanged is a purely
                  -- structural question, independent of whether that id
                  -- has since been renamed to a shadow -- so this scan
                  -- reaches the same answer on the original ids as after
                  -- renaming.
                  invariantIdsPre : SortedSet Int := invariantLoopParamIds (map (\p => (p, RBoxed)) argIds) (collectContinueArgs body')
                  -- One `nativeArgType`/`callArgOrOpNativeTy` call per
                  -- parameter (not batched across `argIds` -- see this
                  -- module's own "Batched, multi-id native-type
                  -- analysis" section and `rc2/doc/loop-conversion.md`
                  -- for why). Variant parameters get the
                  -- richer, call-argument-aware eligibility
                  -- (`callArgOrOpNativeTy`); invariant ones
                  -- deliberately don't (see this function's own doc
                  -- comment above for why) -- each list folds its own
                  -- `invariantIdsPre` membership check directly into the
                  -- same `mapMaybe` pass rather than a separate `filter`
                  -- afterwards, since nothing else ever reads the
                  -- unfiltered eligibility list.
                  -- A parameter read only as a raw pointer (`ptrParams`)
                  -- is shadowed as a `TPtr`, when no `PrimType` read
                  -- claims it.
                  ptrIds : SortedSet Int := ptrParams calleeTable argIds body'
                  nativeTyOf : Maybe PrimType -> Int -> Maybe NativeTy
                  nativeTyOf (Just ty) _ = Just (TPrim ty)
                  nativeTyOf Nothing p = if contains p ptrIds then Just TPtr else Nothing
                  eligibleVariant : List (Int, NativeTy) := mapMaybe (\p => if contains p invariantIdsPre || contains p noPromote
                                                                                then Nothing
                                                                                else map (\ty => (p, ty)) (callArgOrOpNativeTy calleeTable p body'))
                                                                      argIds
                  eligibleInvariant : List (Int, NativeTy) := mapMaybe (\p => if contains p invariantIdsPre && not (contains p noPromote)
                                                                                  then map (\ty => (p, ty)) (nativeTyOf (nativeArgType p body') p)
                                                                                  else Nothing)
                                                                        argIds
                  shadowedVariant : List (Int, Int, NativeTy) := assignShadowIds nextId0 eligibleVariant
                  nextId1 : Int := nextId0 + cast (length eligibleVariant)
                  shadowedInvariant : List (Int, Int, NativeTy) := assignShadowIds nextId1 eligibleInvariant
                  nextId2 : Int := nextId1 + cast (length eligibleInvariant)
                  renamingVariant : Renaming := fromList $ map (\(p, sid, _) => (p, sid)) shadowedVariant
                  shadowIdsVariant : SortedSet Int := fromList $ map (\(_, sid, _) => sid) shadowedVariant
                  -- Every eligible *variant* parameter gets the
                  -- blanket treatment (every occurrence,
                  -- native and Boxed alike, redirected to the shadow) --
                  -- unchanged, deliberately out of scope (see this
                  -- module's own header note above for why a
                  -- loop-carried shadow's own Boxed-context reuse isn't
                  -- addressed here).
                  variantRewritten : RCExp
                  variantRewritten = if null shadowedVariant then body' else stripOwnership shadowIdsVariant (renameRCExp renamingVariant body')
                  -- Invariant parameters only get native-context reads redirected
                  -- (`markInvariantNative`); `stripOwnership` runs once over the whole id set
                  -- (see `rc2/doc/loop-conversion.md`'s "Bugs found and fixed" #7).
                  invariantIdsAll = SortedSet.fromList $ map (\(p, _, _) => p) shadowedInvariant
                  rewritten : RCExp
                  rewritten = foldr (\(p, sid, _), acc => markInvariantNative p sid acc)
                                (stripOwnership invariantIdsAll variantRewritten) shadowedInvariant
                  -- O(P log P) map lookup instead of a `find` (O(P)
                  -- linear scan) called once per `p` in `argIds` (O(P)
                  -- of them) -- see `rc2/doc/loop-conversion.md`.
                  shadowedById : SortedMap Int (Int, NativeTy)
                  shadowedById = SortedMap.fromList $ map (\(p, sid, ty) => (p, (sid, ty))) (shadowedVariant ++ shadowedInvariant)
                  fullLoopParams : List (Int, Rep)
                  fullLoopParams = map (\p => case lookup p shadowedById of
                                               Just (sid, ty) => (sid, RNative ty)
                                               Nothing => (p, RBoxed)) argIds
                  withPostDrop : RCExp
                  withPostDrop = fillLoopContinuePostDrop fullLoopParams (fromList fullLoopParams) rewritten
                  -- The final loop-param id (shadow id if eligible,
                  -- original id otherwise) for every parameter found
                  -- invariant above -- `invariantLoopParamIds`'s own
                  -- pre-rename result (`invariantIdsPre`), translated
                  -- through `fullLoopParams`'s own id mapping. Includes
                  -- both native-shadow-promoted *and* plain-Boxed
                  -- invariant parameters (the latter need no further
                  -- treatment here -- see `applyLoop`'s own doc comment
                  -- above -- but still need excluding from `loopParams`/
                  -- `initial`/every continue's own `args` exactly like
                  -- before).
                  invariantIds : SortedSet Int
                  invariantIds = fromList $ mapMaybe (\(p, finalId) => if contains p invariantIdsPre then Just finalId else Nothing)
                                   (zip argIds (map fst fullLoopParams))
                  loopParams : List (Int, Rep)
                  loopParams = filter (\(p, _) => not (contains p invariantIds)) fullLoopParams
                  finalBody : RCExp
                  finalBody = if null invariantIds
                                 then withPostDrop
                                 else elideInvariantContinueArgs invariantIds fullLoopParams withPostDrop
                  -- Every *still-loop-carried* shadowed param's own
                  -- original top-level arg is dead in its Boxed form
                  -- once its native shadow declaration above runs --
                  -- see `prologueDrop`'s own doc comment on `RLoop` in
                  -- RCExp.idr. An *invariant* shadowed param isn't
                  -- loop-carried any more at all (see
                  -- `wrapInvariantShadows` below) -- its own drop
                  -- happens right there instead, so it's excluded here
                  -- to avoid a double drop.
                  prologueDrop : List RCLocal
                  prologueDrop = mapMaybe (\(p, sid, _) => if contains sid invariantIds then Nothing else Just (RCLoc p))
                                   (shadowedVariant ++ shadowedInvariant)
                  -- Loop-invariant *expression* hoisting (ROp/RCon in
                  -- the loop body's own unconditional prefix, see
                  -- `hoistInvariantPrefix`'s own doc comment): anything
                  -- not a member of the final `loopParams` is, by
                  -- construction, already a loop-external value (a
                  -- plain top-level argument, or something already
                  -- hoisted -- by this pass or the one above), so that
                  -- set alone is the right seed with nothing further to
                  -- compute.
                  hoistResult : (List (Int, Rep, RCExp), RCExp) := hoistInvariantPrefix (fromList (map fst loopParams)) finalBody

                  -- `fst`/`snd hoistResult` each read exactly once
                  -- below, so no separate `hoistedExprs`/`finalBody2`
                  -- names -- just the two projections inline.
                  initial : List RCLocal
                  initial = map snd $ filter (\((p, _), _) => not (contains p invariantIds))
                                              (zip fullLoopParams (map RCLoc argIds))
                  innerLoop : RCExp
                  innerLoop = RLoop emptyFC loopParams initial prologueDrop (snd hoistResult)

                  withHoistedExprs : RCExp
                  withHoistedExprs = foldr (\(var, rep, value), acc => RLet emptyFC var rep value acc) innerLoop (fst hoistResult)
                  -- Wrap each native-shadow-promoted invariant parameter
                  -- with its own one-time `RLet`: if no Boxed-context
                  -- occurrence of `p` survived `markInvariantNative`
                  -- above (`countUsesR` finds none), this is the
                  -- simple shape -- an unconditional `RDrop`
                  -- right after the shadow read. Otherwise (see this
                  -- module's own header note above for the full
                  -- reasoning), every surviving occurrence is `dup`'d
                  -- unconditionally (`dupInvariantBoxed`) and `p`'s own
                  -- single release is deferred until the whole rest of
                  -- the loop (`acc`) has finished evaluating -- bound to
                  -- a fresh `resultVar` first (the same
                  -- bind-then-drop-then-return shape `RC.idr`'s own
                  -- `dropDeadLet` uses), threading `nid` onward so a
                  -- second invariant parameter needing this same
                  -- treatment mints its own, later, `resultVar` rather
                  -- than colliding.
                  wrapInvariantShadows : (Int, RCExp)
                  wrapInvariantShadows =
                      foldr wrapOneInvariant (nextId2, withHoistedExprs)
                        (filter (\(_, sid, _) => contains sid invariantIds) shadowedInvariant)
                    where
                      wrapOneInvariant : (Int, Int, NativeTy) -> (Int, RCExp) -> (Int, RCExp)
                      wrapOneInvariant (p, sid, ty) (nid, acc) =
                          if not (usesInvariant p acc)
                             then (nid, RLet emptyFC sid (RNative ty) (RV emptyFC (RCLoc p)) (RDrop emptyFC [RCLoc p] acc))
                             else
                               let resultVar = nid
                                   dupped = dupInvariantBoxed p acc
                               in (nid + 1, RLet emptyFC sid (RNative ty) (RV emptyFC (RCLoc p))
                                              (RLet emptyFC resultVar retRep dupped
                                                (RDrop emptyFC [RCLoc p] (RV emptyFC (RCLoc resultVar)))))
              in (fst wrapInvariantShadows, MkRCFun args retRep isWorker (snd wrapInvariantShadows))
applyLoopFromId nextId0 _ _ _ d = (nextId0, d)

||| Self-tail-call loop conversion of one top-level definition, given its
||| own `Name` (see `applyLoopFromId`): the `Core` wrapper that supplies the
||| fresh-id counter.
|||
||| Fresh shadow ids are pulled from the shared, whole-compile `VarId`
||| counter (`Compiler.RC2.Util`) -- its current value is already past
||| every id used anywhere in the program (this definition's own
||| included), so no scan for the current highest one in use is
||| needed. `applyLoopFromId` does the actual work as a plain pure
||| function threading that starting id through its own return value; this
||| thin `Core` wrapper reads and writes the shared counter once each.
export
applyLoop : {auto v : Ref VarId Int} -> CalleeTable -> SortedSet Int -> Name -> RCDef -> Core RCDef
applyLoop calleeTable noPromote self d = do
    nextId0 <- get VarId
    let (nextId', d') = applyLoopFromId nextId0 calleeTable noPromote self d
    put VarId nextId'
    pure d'
