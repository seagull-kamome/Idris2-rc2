module Compiler.RC2.Sink

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Branch-local sinking: `let var = value in <branch>` where `var` is
-- only ever genuinely read on *one* arm of the immediately-following
-- branch (RConCase/RConstCase/RCmpCase) gets rewritten to move
-- `value`'s own computation into that one arm instead, deleting the
-- stale "unused here" RDrop the other arm(s) had for `var`.
--
-- Found while reading tests/Test21BoxedInvariantNotHoisted.idr's own
-- `.rcexpr` dump (Compiler.RC2.Loop's own loop-invariant expression
-- hoisting, which deliberately never hoists a Boxed-Rep binding out of
-- a loop -- see that module's own doc comment): its `let v5 = MkCtx
-- tag extra` sits in the loop's own unconditional prefix even though
-- `v5` is only ever read on the loop's *exit* arm, so it gets rebuilt
-- (and immediately dropped, unused) on every single iteration that
-- keeps looping. Unlike hoisting, this doesn't depend on loop-carried
-- values being invariant at all -- `v5`'s own operands could just as
-- well be varying loop parameters and the same rewrite would still be
-- correct, since it only ever *reduces* how many times `value` gets
-- computed (down to "only on the one arm that actually needs it,
-- exactly when it's reached" -- strictly fewer executions than
-- hoisting's own "exactly once per call, regardless of which arm
-- eventually fires," and *far* fewer than the original "once per
-- iteration, discarded on every iteration but the last"). That's why
-- this lives as its own general pass over `let ... in <branch>`
-- rather than folding into `Compiler.RC2.Loop`: nothing about it is
-- loop-specific.

import Compiler.RC2.RCExp
import Compiler.RC2.Types

import Core.CompileExpr
import Core.FC
import Core.TT

import Data.List
import Data.SortedMap
import Data.SortedSet
import Data.Vect

%default covering

------------------------------------------------------------------------
-- Which locals a branch genuinely *reads* -- deliberately distinct
-- from RCExp.idr's own `freeLocalsR`, which counts an `RDrop`'s own
-- `vars` (and `RFree`/`RReleaseReuse`'s own target) as a "use" too.
-- For sinking, an appearance *only* inside one of those is exactly the
-- "unused here, already correctly released" shape this pass looks
-- for -- counting it as a genuine read would make every sink candidate
-- look used everywhere, defeating the whole point.

||| Every `RCLocal` genuinely read anywhere in `e` -- same shape as
||| `freeLocalsR`, except `RDrop`/`RFree`/`RReleaseReuse`'s own
||| target(s) contribute nothing (see the module note above for why),
||| and `RLoop`/`RLoopContinue` are covered (this pass runs after
||| `Compiler.RC2.Loop`, unlike every other tree-walk in this
||| codebase that predates it -- see `RC2.idr`'s own pipeline).
genuinelyUsedR : RCExp -> SortedSet RCLocal
genuinelyUsedR (RV _ v) = singleton v
genuinelyUsedR (RAppName _ _ _ args) = fromList args
genuinelyUsedR (RUnderApp _ _ _ args) = fromList args
genuinelyUsedR (RApp _ _ c a) = fromList [c, a]
genuinelyUsedR (RAppNameRep _ _ _ _ _ args) = fromList args
genuinelyUsedR (RLet _ var _ value body) =
    union (genuinelyUsedR value) (delete (RCLoc var) (genuinelyUsedR body))
genuinelyUsedR (RCon _ _ _ _ args _) = fromList args
genuinelyUsedR (ROp _ _ _ args _) = fromList (toList args)
genuinelyUsedR (RExtPrim _ _ _ args) = fromList args
genuinelyUsedR (RStructGet _ structVar _ _ _) = singleton structVar
genuinelyUsedR (RStructSet _ structVar _ _ value _) = fromList [structVar, value]
genuinelyUsedR (RCmpCase _ _ args _ t f) =
    union (fromList (toList args)) (union (genuinelyUsedR t) (genuinelyUsedR f))
genuinelyUsedR (RConCase _ sc alts mDef) =
    let altsUsed = map (\(MkRConAlt _ _ _ as body) =>
                          difference (genuinelyUsedR body) (fromList (map RCLoc as))) alts
        allUsed = maybe altsUsed (\d => genuinelyUsedR d :: altsUsed) mDef
    in insert sc (concat allUsed)
genuinelyUsedR (RConstCase _ sc alts mDef) =
    let altsUsed = map (\(MkRConstAlt _ body) => genuinelyUsedR body) alts
        allUsed = maybe altsUsed (\d => genuinelyUsedR d :: altsUsed) mDef
    in insert sc (concat allUsed)
genuinelyUsedR (RDup _ v body) = insert v (genuinelyUsedR body)
genuinelyUsedR (RDrop _ _ body) = genuinelyUsedR body
genuinelyUsedR (RFree _ _ body) = genuinelyUsedR body
genuinelyUsedR (RReleaseReuse _ _ body) = genuinelyUsedR body
genuinelyUsedR (RReuseOffer _ sc dupOnShared body) =
    union (insert sc (fromList dupOnShared)) (genuinelyUsedR body)
genuinelyUsedR (RLoop _ _ initial _ body) = union (fromList initial) (genuinelyUsedR body)
genuinelyUsedR (RLoopContinue _ args postDrop) = union (fromList args) (fromList postDrop)
genuinelyUsedR _ = empty

||| Strips every occurrence of `var` from any `RDrop`'s own `vars` list
||| anywhere in `e` (removing the whole `RDrop` node if that empties
||| it) -- only ever called once `genuinelyUsedR` has already confirmed
||| `var` is never genuinely read in `e`, so this can never remove a
||| drop protecting a real use. Walks the whole tree rather than just
||| `e`'s own leading wrapper chain: `Compiler.RC2.RC`'s own `annotate`
||| places "at most one `RDrop` per branch entry" (see
||| `Compiler.RC2.ConAltNative`'s own `peelWrappers` doc comment for
||| this same convention relied on elsewhere), but this pass runs after
||| both `Compiler.RC2.Reuse` and `Compiler.RC2.Loop` have *also* run,
||| and neither documents never nesting a further branch inside an
||| already-dead arm, so a full walk is the only way to be sure.
removeVarDrop : Int -> RCExp -> RCExp
removeVarDrop var (RLet fc v rep value body) = RLet fc v rep value (removeVarDrop var body)
removeVarDrop var (RDup fc v body) = RDup fc v (removeVarDrop var body)
removeVarDrop var (RDrop fc vars body) =
    let vars' = filter (/= RCLoc var) vars
        body' = removeVarDrop var body
    in if null vars' then body' else RDrop fc vars' body'
removeVarDrop var (RFree fc v body) = RFree fc v (removeVarDrop var body)
removeVarDrop var (RReleaseReuse fc v body) = RReleaseReuse fc v (removeVarDrop var body)
removeVarDrop var (RReuseOffer fc sc dupOnShared body) = RReuseOffer fc sc dupOnShared (removeVarDrop var body)
removeVarDrop var (RCmpCase fc op args pd t f) = RCmpCase fc op args pd (removeVarDrop var t) (removeVarDrop var f)
removeVarDrop var (RConCase fc sc alts mDef) =
    RConCase fc sc (map (\(MkRConAlt n ci tag as body) => MkRConAlt n ci tag as (removeVarDrop var body)) alts)
      (map (removeVarDrop var) mDef)
removeVarDrop var (RConstCase fc sc alts mDef) =
    RConstCase fc sc (map (\(MkRConstAlt c body) => MkRConstAlt c (removeVarDrop var body)) alts)
      (map (removeVarDrop var) mDef)
removeVarDrop var (RLoop fc loopParams initial prologueDrop body) =
    RLoop fc loopParams initial prologueDrop (removeVarDrop var body)
removeVarDrop _ e = e

||| `Nothing` if `var` is genuinely read anywhere in `branch` (a
||| candidate for the *one* arm `value` sinks into); `Just` the
||| rewritten branch (its own stale `drop [var, ...]`, if any, stripped
||| -- unchanged otherwise) if `var` is never genuinely read there at
||| all.
stripIfUnused : Int -> RCExp -> Maybe RCExp
stripIfUnused var branch =
    if contains (RCLoc var) (genuinelyUsedR branch)
       then Nothing
       else Just (removeVarDrop var branch)

||| `RCLocal`'s own representation, given `reps` -- the same "missing
||| id defaults to `RBoxed`" convention `Compiler.RC2.DualABI`'s own
||| `localRepIn` uses (a top-level function argument, or one of this
||| loop's own `RLoop`-carried params/`RLet`-bound locals not yet seen,
||| is always genuinely Boxed at that point -- `reps` only ever records
||| a *promotion* away from that default).
localRepIn : SortedMap Int Rep -> RCLocal -> Rep
localRepIn _ RCNull = RBoxed
localRepIn reps (RCLoc i) = fromMaybe RBoxed (lookup i reps)
localRepIn _ (RCConst c) = fromMaybe RBoxed (RNative <$> litRep c)
localRepIn _ (RCEmptyCon {}) = RBoxed

||| Every Boxed operand `value` itself *consumes* by reading it -- an
||| `ROp`'s own `postDrop` list; every Boxed argument of an `RAppName`
||| (a call transfers ownership of *all* its own arguments to the
||| callee unconditionally, unlike `ROp`'s own curated `postDrop` --
||| `reps` is what lets this filter out an already-native argument,
||| which never needs (or permits) an `RDrop` entry at all); or
||| (tracked via `dupped`, every id a leading `RDup` already protected
||| with its own extra reference) any `RCon` field *not* `dup`'d first
||| -- the field's own sole remaining reference then moves straight
||| into the new constructor rather than surviving independently
||| (contrast `tests/Test21BoxedInvariantNotHoisted.idr`'s own `dup v0;
||| dup v1; con _ [v0, v1]`, where both fields *are* `dup`'d first, so
||| `v0`/`v1` themselves keep living on past the `con` -- correctly not
||| counted here, `consumedOperands` for that one is `[]`).
|||
||| Found the hard way: `tests/Test9SelfTailLoop.idr`'s own
||| (transitively pulled in Prelude) `Prelude.Types.getAt` has `let v4
||| = op -Integer [v0, #1] postDrop=[v0] in case v1 of Cons ... =>
||| ...v4...; Nil => (v4 unused)`. Before this fix, sinking `v4`'s own
||| binding into the `Cons` arm carried `postDrop=[v0]` along with it
||| -- meaning `v0` only got released on iterations that actually take
||| that arm. On the `Nil` arm, nothing ever reads `v0` at all any more
||| (that arm doesn't mention `v4`, so `v0` -- only ever reachable
||| *through* computing `v4` -- never gets read there either), a
||| genuine `valgrind`-confirmed leak. `addOperandDrops` (below) is
||| what plugs this: every arm `value` does *not* sink into gets an
||| explicit `drop` for these operands instead, exactly replacing the
||| release `value`'s own `postDrop`/field-move used to unconditionally
||| provide every time (see that function's own doc comment for why
||| this is always safe to add).
consumedOperands : SortedMap Int Rep -> RCExp -> List RCLocal
consumedOperands reps = go []
  where
    isBoxed : RCLocal -> Bool
    isBoxed a = case localRepIn reps a of
                     RBoxed => True
                     _ => False
    go : List RCLocal -> RCExp -> List RCLocal
    go _ (ROp _ _ _ _ postDrop) = postDrop
    go _ (RAppName _ _ _ args) = filter isBoxed args
    go dupped (RCon _ _ _ _ args _) = filter (\a => not (a `elem` dupped)) args
    go dupped (RDup _ v cont) = go (v :: dupped) cont
    go dupped (RDrop _ _ cont) = go dupped cont
    go dupped (RFree _ _ cont) = go dupped cont
    go dupped (RReleaseReuse _ _ cont) = go dupped cont
    go _ _ = []

||| Prefixes `branch` (already rewritten by `stripIfUnused` -- `var`
||| itself confirmed absent) with a `drop` for every one of `consumed`
||| -- the operands `value` itself would have consumed had it run here
||| -- unless any of them is genuinely read in `branch` already (an
||| operand `value` reads can't *also* be independently read by this
||| arm's own unrelated logic under this pass's own sinking shape, so
||| this should never actually fire, but bailing out to `Nothing`
||| rather than risking a double-drop costs nothing). `Nothing`
||| (falling back to not sinking at all) in that case; `Just branch`
||| unchanged when `consumed` is empty (the overwhelmingly common
||| case -- most `ROp`s read only already-native, or otherwise
||| never-consumed, operands).
addOperandDrops : FC -> List RCLocal -> RCExp -> Maybe RCExp
addOperandDrops _ [] branch = Just branch
addOperandDrops fc consumed branch =
    if any (\op => contains op (genuinelyUsedR branch)) consumed
       then Nothing
       else Just (RDrop fc consumed branch)

------------------------------------------------------------------------
-- Deciding whether `value` itself is even a candidate to sink at all.

||| Whether `value` (after peeling the same leading `RDup`/`RDrop`/
||| `RFree`/`RReleaseReuse` shapes `Compiler.RC2.Loop`'s own
||| `isInvariantExpr` already peels for an analogous reason) is a bare
||| `ROp`/`RCon`/`RAppName` -- deliberately excluding a `Lazy`-marked
||| `ROp`/`RAppName` (its evaluation *timing* is itself observable,
||| `Compiler.RC2.Loop`'s own `isInvariantExpr` doc comment has the
||| full reasoning) and a `reuseFrom`-tied `RCon` (entangled with a
||| specific `RReuseOffer`'s own per-arm runtime protocol, not this
||| pass's to relocate) -- conservative parity with that same
||| function's own exclusions, kept in sync deliberately rather than
||| re-derived independently.
|||
||| `RAppName` (an ordinary, named call) is eligible here even though
||| `Compiler.RC2.Loop`'s own hoisting deliberately excludes it: that
||| exclusion is specific to *hoisting* (moving a computation to run
||| unconditionally, once per call, ahead of a loop that might
||| otherwise have skipped it on a zero-iteration path -- see that
||| module's own doc comment). Sinking only ever *reduces* how many
||| times `value` runs, so the same worry doesn't apply -- a call that
||| would have executed regardless is still guaranteed to, now simply
||| closer to (and only when reaching) its one actual use.
||| `RApp`/`RUnderApp` (closure application/building) stay out of scope
||| deliberately -- more machinery (allocation, the trampoline) than a
||| direct named call, not analysed here. `RExtPrim` (genuine
||| `%World`-threaded effects) is never eligible, sunk or not.
sinkEligible : RCExp -> Bool
sinkEligible (ROp _ Nothing _ _ _) = True
sinkEligible (RCon _ _ _ _ _ Nothing) = True
sinkEligible (RAppName _ Nothing _ _) = True
sinkEligible (RDup _ _ cont) = sinkEligible cont
sinkEligible (RDrop _ _ cont) = sinkEligible cont
sinkEligible (RFree _ _ cont) = sinkEligible cont
sinkEligible (RReleaseReuse _ _ cont) = sinkEligible cont
sinkEligible _ = False

------------------------------------------------------------------------
-- The rewrite itself, per branch-node shape.

||| Whether `var` is himself one of the *operands deciding which arm
||| runs* -- an `RCmpCase`'s own comparison args, or an `RConCase`/
||| `RConstCase`'s own scrutinee. This must be evaluated *before* any
||| arm ever runs, so sinking `value` into one specific arm is
||| impossible when it's the very thing being branched on: a real bug,
||| caught by `tests/Test2Recursion.idr`'s own `fib` during
||| development -- `let v1 = v0 - 1 in case v1 of 0 => ...; _ => (uses
||| v1 to compute v0's own fib)` looks, to a check that only scans each
||| arm's own *body*, exactly like "one arm uses it, the other doesn't"
||| (the `0` arm never reads `v1` again; the `_` arm does) -- sinking
||| `v1`'s own binding into the `_` arm produces `case v1 of ...`
||| referencing `v1` before it's ever declared. `trySinkInto` checks
||| this before ever calling `trySinkIntoArms` below.
isDecidingOperand : Int -> RCExp -> Bool
isDecidingOperand var (RCmpCase _ _ args _ _ _) = RCLoc var `elem` toList args
isDecidingOperand var (RConCase _ sc _ _) = sc == RCLoc var
isDecidingOperand var (RConstCase _ sc _ _) = sc == RCLoc var
isDecidingOperand _ _ = False

||| Try to sink `RLet _ var rep value _`'s own binding into the single
||| arm of `branch` (an `RCmpCase`/`RConCase`/`RConstCase`, `var` not
||| itself its own deciding operand, see `isDecidingOperand`) that
||| genuinely reads `var`, every other arm rewritten to drop the now-
||| stale `drop [var, ...]` it used to need (see `stripIfUnused`).
||| `Nothing` if `var`'s own usage across the arms isn't "exactly one
||| genuinely reads it, every other one doesn't" -- two-or-more-arms-
||| use-it and zero-arms-use-it are both left alone (the first has
||| nothing to gain from sinking into just one arm; the second means
||| `var` is truly dead code, not this pass's problem to clean up).
||| `stripIfUnused var branch`, then -- only when that confirms `var`
||| unused there -- also patches in a `drop` for `value`'s own
||| `consumedOperands` (see that function's own doc comment), using
||| `fc` (the *enclosing branch node's* own `FC` -- a fresh `RDrop`
||| needs one of its own, and this arm's own body isn't necessarily a
||| branch node itself to borrow one from) for the new `RDrop`. Folds
||| both steps into one so every call site below gets the leak fix for
||| free: `Nothing` (bail, don't sink) now covers both "`var` genuinely
||| used here" and "one of `value`'s own consumed operands is too" (the
||| latter should never actually happen -- see `addOperandDrops`'s own
||| doc comment -- but costs nothing to guard against).
stripForSink : Int -> FC -> List RCLocal -> RCExp -> Maybe RCExp
stripForSink var fc consumed branch = stripIfUnused var branch >>= addOperandDrops fc consumed

trySinkIntoArms : SortedMap Int Rep -> Int -> Rep -> RCExp -> RCExp -> Maybe RCExp
trySinkIntoArms reps var rep value (RCmpCase fc op args pd t f) =
    let consumed = consumedOperands reps value
    in case (stripForSink var fc consumed t, stripForSink var fc consumed f) of
            (Nothing, Just f') => Just $ RCmpCase fc op args pd (RLet fc var rep value t) f'
            (Just t', Nothing) => Just $ RCmpCase fc op args pd t' (RLet fc var rep value f)
            _ => Nothing
trySinkIntoArms reps var rep value (RConCase fc sc alts mDef) =
    let consumed = consumedOperands reps value
        altStripped : List (RConAlt, Maybe RCExp)
        altStripped = map (\alt@(MkRConAlt _ _ _ _ body) => (alt, stripForSink var fc consumed body)) alts
        defStripped : Maybe (RCExp, Maybe RCExp)
        defStripped = map (\d => (d, stripForSink var fc consumed d)) mDef
        usedCount : Nat
        defResults : List (Maybe RCExp)
        defResults = case defStripped of
                          Nothing => []
                          Just (_, r) => [r]
        usedCount = length (filter isNothing (map snd altStripped ++ defResults))
    in if usedCount /= 1
          then Nothing
          else Just $ RConCase fc sc
                 (map (\(MkRConAlt n ci tag as orig, r) =>
                          MkRConAlt n ci tag as (case r of
                                                       Nothing => RLet fc var rep value orig
                                                       Just b => b)) altStripped)
                 (map (\(orig, r) => case r of
                                           Nothing => RLet fc var rep value orig
                                           Just b => b) defStripped)
trySinkIntoArms reps var rep value (RConstCase fc sc alts mDef) =
    let consumed = consumedOperands reps value
        altStripped : List (RConstAlt, Maybe RCExp)
        altStripped = map (\alt@(MkRConstAlt _ body) => (alt, stripForSink var fc consumed body)) alts
        defStripped : Maybe (RCExp, Maybe RCExp)
        defStripped = map (\d => (d, stripForSink var fc consumed d)) mDef
        usedCount : Nat
        defResults : List (Maybe RCExp)
        defResults = case defStripped of
                          Nothing => []
                          Just (_, r) => [r]
        usedCount = length (filter isNothing (map snd altStripped ++ defResults))
    in if usedCount /= 1
          then Nothing
          else Just $ RConstCase fc sc
                 (map (\(MkRConstAlt c orig, r) =>
                          MkRConstAlt c (case r of
                                              Nothing => RLet fc var rep value orig
                                              Just b => b)) altStripped)
                 (map (\(orig, r) => case r of
                                           Nothing => RLet fc var rep value orig
                                           Just b => b) defStripped)
trySinkIntoArms _ _ _ _ _ = Nothing

||| Sees through the same leading `RDup`/`RDrop`/`RFree`/
||| `RReleaseReuse`/`RReuseOffer` wrappers `stripIfUnused` itself sees
||| through -- *unless* the wrapper's own target(s) include `var`
||| itself, in which case sinking stops right there (`Nothing`): a real
||| bug, caught by `refc-suite/buffer`'s own `TestBuffer.idr` during
||| development. `let v5 = call prim__setByte ... in drop [v5]; let v6
||| = call prim__setBits8 ... in drop [v6]; ...` (a chain of
||| side-effecting calls whose own `IORes ()`-shaped result is
||| immediately discarded) has `v5` wrapped by exactly one `RDrop [v5]`
||| right after its own binding -- before this fix, the old
||| unconditional "peel through any RDrop" clause treated that as just
||| another non-branching wrapper to see past, entirely missing that
||| *this specific* `RDrop` is `v5`'s own death, and kept searching
||| straight through `v6`/`v7`/`v8`'s own identical chain all the way
||| to a distant, unrelated branch far downstream -- producing a
||| miscompile (`var_5`/`var_6`/... referenced in generated C without
||| ever being declared there). Every wrapper case below now checks its
||| own target(s) against `var` first, mirroring the same reasoning the
||| `RLet` case (below) already applies to `y`'s own `valueY`.
|||
||| Also sees through a leading `RLet` for some unrelated local `y`
||| (`var`'s own binding sinks *past* `y`'s, leaving it exactly where
||| it is), then dispatches to `trySinkIntoArms` -- guarded by
||| `isDecidingOperand` first (see its own doc comment for the real bug
||| *that* guard fixes).
|||
||| The `RLet` case only fires for a `y` that couldn't itself be sunk
||| into the branch beneath it (if it could, `applySinkExp`'s own
||| innermost-first walk already rewrote `let y = .. in <branch>` into
||| that very branch, with `y`'s own binding moved inside one arm --
||| see that function's own doc comment -- so by the time `var`'s own
||| `trySinkInto` runs, this `RLet` shape only survives when `y` itself
||| had nowhere to go, e.g. read on more than one arm). Bails
||| (`Nothing`) if `y`'s own `valueY` reads `var` -- that read happens
||| unconditionally, regardless of which branch arm eventually runs, so
||| `var` is genuinely needed before any arm, exactly the same
||| reasoning `isDecidingOperand` already applies to a branch's own
||| scrutinee/comparison operands.
trySinkInto : SortedMap Int Rep -> Int -> Rep -> RCExp -> RCExp -> Maybe RCExp
trySinkInto reps var rep value (RDup fc v cont) =
    if v == RCLoc var then Nothing else map (RDup fc v) (trySinkInto reps var rep value cont)
trySinkInto reps var rep value (RDrop fc vs cont) =
    if RCLoc var `elem` vs then Nothing else map (RDrop fc vs) (trySinkInto reps var rep value cont)
trySinkInto reps var rep value (RFree fc v cont) =
    if v == RCLoc var then Nothing else map (RFree fc v) (trySinkInto reps var rep value cont)
trySinkInto reps var rep value (RReleaseReuse fc v cont) =
    if v == RCLoc var then Nothing else map (RReleaseReuse fc v) (trySinkInto reps var rep value cont)
trySinkInto reps var rep value (RReuseOffer fc sc dupOnShared cont) =
    if (sc == RCLoc var) || (RCLoc var `elem` dupOnShared)
       then Nothing
       else map (RReuseOffer fc sc dupOnShared) (trySinkInto reps var rep value cont)
trySinkInto reps var rep value (RLet fc y repY valueY cont) =
    if contains (RCLoc var) (genuinelyUsedR valueY)
       then Nothing
       else map (RLet fc y repY valueY) (trySinkInto reps var rep value cont)
trySinkInto reps var rep value branch@(RCmpCase _ _ _ _ _ _) =
    if isDecidingOperand var branch then Nothing else trySinkIntoArms reps var rep value branch
trySinkInto reps var rep value branch@(RConCase _ _ _ _) =
    if isDecidingOperand var branch then Nothing else trySinkIntoArms reps var rep value branch
trySinkInto reps var rep value branch@(RConstCase _ _ _ _) =
    if isDecidingOperand var branch then Nothing else trySinkIntoArms reps var rep value branch
trySinkInto _ _ _ _ _ = Nothing

------------------------------------------------------------------------
-- Whole-tree application.

||| Walks the whole tree, innermost-first (a `RLet`'s own `body` is
||| fully sunk *before* trying to sink the `RLet` itself), so a chain
||| `let a = .. in let b = f a in <branch>` resolves in one pass: `b`
||| sinks into its one using arm first, then `a` -- now only reachable
||| through that same arm's own (already-sunk) `let b = ...` -- sinks
||| into the very same place right behind it, no fixed-point iteration
||| needed (mirrors `Compiler.RC2.Loop`'s own `hoistInvariantPrefix`
||| reasoning, just in the opposite direction).
|||
||| A successful sink is re-fed through `applySinkExp` itself (rather
||| than returned as-is) so a chain of *nested* single-use branches
||| resolves in one pass too: once `var`'s own binding lands at the top
||| of the one arm that reads it, that arm's own body might itself
||| start with another branch `var` is only read on one side of --
||| `sunk`'s own top-level shape is now that branch node (`var`'s own
||| `RLet` moved *inside* one of its arms), so re-walking it lets
||| `trySinkInto` fire again, one level deeper. Always terminates: each
||| successful sink strictly relocates `var`'s own binding site into a
||| strictly smaller subtree of a finite tree; a failed attempt (or no
||| deeper branch to sink into) just stops there.
||| `reps` threads which locals are already known non-`RBoxed` -- seeded
||| from the enclosing function's own top-level args (all `RBoxed`, so
||| nothing to seed there, see `applySink` below), extended at every
||| `RLet` (its own declared `Rep`) and `RLoop` (its own `loopParams`)
||| -- the same shape `Compiler.RC2.Loop`'s own `fillLoopContinuePostDrop`/
||| `Compiler.RC2.DualABI`'s own `applyCallSiteRewriteBody` already
||| thread through, for the analogous reason (`consumedOperands` needs
||| it to tell a genuinely Boxed `RAppName` argument from an
||| already-native one, see that function's own doc comment).
export
applySinkExp : SortedMap Int Rep -> RCExp -> RCExp
applySinkExp reps (RLet fc var rep value body) =
    let value' = applySinkExp reps value
        reps' = insert var rep reps
        body' = applySinkExp reps' body
    in if sinkEligible value'
          then case trySinkInto reps' var rep value' body' of
                    Just sunk => applySinkExp reps sunk
                    Nothing => RLet fc var rep value' body'
          else RLet fc var rep value' body'
applySinkExp reps (RCmpCase fc op args pd t f) = RCmpCase fc op args pd (applySinkExp reps t) (applySinkExp reps f)
applySinkExp reps (RConCase fc sc alts mDef) =
    RConCase fc sc (map (\(MkRConAlt n ci tag as body) => MkRConAlt n ci tag as (applySinkExp reps body)) alts)
      (map (applySinkExp reps) mDef)
applySinkExp reps (RConstCase fc sc alts mDef) =
    RConstCase fc sc (map (\(MkRConstAlt c body) => MkRConstAlt c (applySinkExp reps body)) alts)
      (map (applySinkExp reps) mDef)
applySinkExp reps (RDup fc v body) = RDup fc v (applySinkExp reps body)
applySinkExp reps (RDrop fc vs body) = RDrop fc vs (applySinkExp reps body)
applySinkExp reps (RFree fc v body) = RFree fc v (applySinkExp reps body)
applySinkExp reps (RReleaseReuse fc v body) = RReleaseReuse fc v (applySinkExp reps body)
applySinkExp reps (RReuseOffer fc sc dupOnShared body) = RReuseOffer fc sc dupOnShared (applySinkExp reps body)
applySinkExp reps (RLoop fc loopParams initial prologueDrop body) =
    RLoop fc loopParams initial prologueDrop (applySinkExp (foldl (\m, (i, r) => insert i r m) reps loopParams) body)
applySinkExp _ e = e

||| Apply branch-local sinking to one top-level definition. Every
||| top-level argument is genuinely `RBoxed` (the external calling
||| convention), which is exactly `localRepIn`'s own default for an id
||| missing from `reps` -- nothing to seed there.
export
applySink : RCDef -> RCDef
applySink (MkRCFun args retRep body) = MkRCFun args retRep (applySinkExp empty body)
applySink (MkRCError body) = MkRCError (applySinkExp empty body)
applySink d@(MkRCCon _ _ _) = d
applySink d@(MkRCForeign _ _ _) = d
