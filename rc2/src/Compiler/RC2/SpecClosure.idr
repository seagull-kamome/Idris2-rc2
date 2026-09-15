||| Speculative, profitability-gated closure-argument specialization.
||| See `rc2/doc/speculative-closure-specialization.md` for the full
||| motivation and paper design this module implements. Summary: for a
||| function `g` whose parameter `p` is used only via `RApp` (a boxed
||| closure dispatch) inside `g`'s own body, and which is *always*
||| called with one specific known closure target at some subset of
||| `g`'s own call sites (program-wide, ignoring what free variables
||| that closure happens to capture at each such site -- a strictly
||| weaker property than `%spec`'s own closedness requirement, see the
||| doc's "Why not just use upstream %spec" section), clone `g` once
||| per distinct target actually observed, rewrite the clone's own
||| `apply` into a direct `call`, and keep the clone only if that
||| direct call is no longer hidden behind any remaining `apply` of the
||| same kind after a fresh `ConstFold` pass over just the clone --
||| discard it otherwise. A discarded clone is simply never referenced
||| by anything and costs nothing (`Compiler.RC2.DeadCode` drops it like
||| any other unreferenced definition).
|||
||| Runs once, between `Compiler.RC2.RC2`'s own `foldConstProgram` and
||| `insertMemoize` (`RC2.idr`'s own `toRCDefs`) -- strictly after
||| `RUnderApp` targets are visible (`ConstFold` has already resolved
||| every locally-foldable one), strictly before Phase 2 (`annotate`)
||| ever runs, so a kept clone is just one more plain `MkRCFun` in the
||| list handed to the rest of the pipeline -- it needs no special
||| handling of its own from `annotate`/`Reuse`/`ConAltNative`/`Loop`/
||| etc., all of which already run per-definition regardless of how a
||| definition came to exist.
|||
||| **Scope limits, both deliberate, both documented rather than silently
||| assumed**:
||| - `missing > 1` (the closure needs more than one more argument
|||   before it's saturated) *is* handled, via `chainArgs` below --
|||   `RApp`'s own two operands are bare `RCLocal`s, never a nested
|||   `RApp`, so a curried `f a1 a2` ANF-normalizes to `RLet tmp (RApp f
|||   a1) (RApp tmp a2)`, not one node -- but only the *exact* shape
|||   `chainArgs` recognizes (each apply's own result immediately
|||   feeding the next, nothing else interposed) is specialized; a
|||   chain interrupted by anything else (another `RLet` unrelated to
|||   the chain, a case split before the last apply, ...) is left alone
|||   -- conservative, no partial credit. Confirmed empirically to
|||   matter, not a hypothetical: an ordinary `String -> IO ()` callback
|||   -- the design doc's own motivating shape verbatim -- lowers to
|||   `missing = 2` here (the real argument, then the hidden `%World`
|||   token IO's own calling convention threads through), never
|||   `missing = 1` -- a `missing == 1`-only first cut of this module
|||   turned out to miss its own motivating case entirely.
||| - This module's own "re-run `Inline` on the clone" half of the paper
|||   design's Step 2 is NOT implemented -- `Compiler.RC2.Inline` is a
|||   whole-program `Lifted`-to-`Lifted` pass that already ran once,
|||   before this pipeline stage, at the pre-RCExp level; re-invoking it
|||   on a single already-RCExp clone isn't something its current
|||   architecture supports (the paper design's own "Where in the
|||   pipeline this runs" open question, never resolved). Only
||| `Compiler.RC2.ConstFold`'s `foldConstDef` is re-run here. A target
|||   that's itself small and call-free is therefore not opportunistically
|||   inlined into the clone by this pass -- it stays a real direct call.
||| - Applied once per compile (not iterated to a fixpoint), by explicit
|||   request -- see this module's own doc comment on `applySpecClosure`
|||   for why it's still written to make a later fixpoint wrapper a
|||   trivial addition, not a redesign.
module Compiler.RC2.SpecClosure

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Compiler.RC2.ConstFold
import Compiler.RC2.RCExp
import Compiler.RC2.Types
import Compiler.RC2.Util

import Core.Context
import Core.Core
import Core.FC
import Core.TT

import Data.DPair
import Data.List
import Data.Maybe
import Data.SortedMap
import Data.SortedSet

%default covering

------------------------------------------------------------------------
-- Step 1: whole-program call-site discovery
------------------------------------------------------------------------

||| A closure some call site is passing that's provably always one
||| specific `RUnderApp`'s value -- `target`/`missing` are `RUnderApp`'s
||| own first two fields (the part that must agree for two call sites
||| to count as "the same target"); `capturedArgs` is `RUnderApp`'s own
||| third field, the actual values closed over *at this one call site*
||| -- varies freely between call sites sharing the same `target`
||| (`speculative-closure-specialization.md`'s own `[v85, v80]` vs.
||| `[v200, v201]` example).
record KnownClosure where
  constructor MkKnownClosure
  target : Name
  missing : Nat
  capturedArgs : List RCLocal

||| One call site passing a `KnownClosure` for one of its own arguments.
||| `callee`/`argPos` identify which parameter of which function
||| received it -- `argPos` is a plain list index into both the call's
||| own `args` and (assumed to line up 1:1, true for an ordinary
||| saturated `RAppName`) the callee's own `MkRCFun` `args`.
record Opportunity where
  constructor MkOpportunity
  callee : Name
  argPos : Nat
  closure : KnownClosure

||| Which `RCLocal`s, in the definition currently being walked, are
||| provably bound (via an enclosing `RLet`) to a known `RUnderApp`
||| value, keyed by their own `Int` id. Built forward, never popped:
||| `Compiler.RC2.RC`'s own `normalizeDef` (`nextVarId`) assigns every
||| `RLet`'s own `var` a fresh, monotonically increasing `Int` once per
||| definition, so no id is ever rebound within one definition's own
||| body -- an entry inserted here stays correct for the rest of that
||| body, including inside nested case alternatives.
Bound : Type
Bound = SortedMap Int KnownClosure

||| The `KnownClosure` an argument value already carries, if any --
||| either a `RCLoc i` traced back through `bound` to an enclosing
||| `RLet`'s own `RUnderApp` (the general case, some real value
||| captured), or a bare `RCConstClosure n missing` sitting directly in
||| the argument position with no `RLet`/`Bound` lookup needed at all.
||| The latter is what a *zero*-capture `RUnderApp` (`RUnderApp fc n
||| missing []`) already becomes by the time this pass ever sees it --
||| `Compiler.RC2.ConstFold`'s own existing, narrower constant-closure
||| folding (`rc2/doc/const-closure-fold.md`) already collapses it to
||| that bare marker and substitutes it at every use site directly,
||| leaving no `RLet`/`Bound` entry behind to trace back to (confirmed
||| empirically: this module's own motivating case, an ordinary
||| `mkTarget prefix` where `prefix` is itself a string *literal*, folds
||| this way -- the literal itself constant-folds away first, leaving a
||| zero-capture reference `ConstFold` already resolves on its own,
||| missed entirely by an earlier version of this function that only
||| ever checked `Bound`).
lookupKnown : Bound -> RCLocal -> Maybe KnownClosure
lookupKnown bound (RCLoc i) = lookup i bound
lookupKnown _ (RCConstClosure n missing) = Just (MkKnownClosure n missing [])
lookupKnown _ _ = Nothing

||| Every `Opportunity` in `e`, given what's already known bound in
||| `bound` from enclosing `RLet`s. Only descends into nodes that can
||| appear before `Compiler.RC2.RC`'s own `annotate` (Phase 2) has run
||| -- this pass sits strictly before it in `toRCDefs`, so `RDup`/
||| `RDrop`/`RFree`/`RReleaseReuse`/`RReuseOffer` (Phase 2's own
||| output), `RLoop`/`RLoopContinue` (`Compiler.RC2.Loop`, later still),
||| `RAppNameRep`/`RAppFFIInline` (`Compiler.RC2.DualABI`, later still)
||| and `RMemoize` (`insertMemoize`, which itself runs *after* this
||| pass, `RC2.idr`'s own `toRCDefs`) can none of them actually occur in
||| the input this function ever receives.
collectOpportunities : Bound -> RCExp -> List Opportunity
collectOpportunities bound (RLet fc var _ value body) =
    let valueOpps = collectOpportunities bound value
        bound' = case value of
                      RUnderApp _ n missing capturedArgs =>
                          insert var (MkKnownClosure n missing capturedArgs) bound
                      _ => bound
    in valueOpps ++ collectOpportunities bound' body
collectOpportunities bound (RAppName _ _ callee args) =
    mapMaybe (\(i, a) => map (MkOpportunity callee i) (lookupKnown bound a))
             (zip [0 .. length args] args)
collectOpportunities bound (RCmpCase _ _ _ _ t f) =
    collectOpportunities bound t ++ collectOpportunities bound f
collectOpportunities bound (RConCase _ _ alts mDef) =
    concatMap (\(MkRConAlt _ _ _ _ body) => collectOpportunities bound body) alts
    ++ maybe [] (collectOpportunities bound) mDef
collectOpportunities bound (RConstCase _ _ alts mDef) =
    concatMap (\(MkRConstAlt _ body) => collectOpportunities bound body) alts
    ++ maybe [] (collectOpportunities bound) mDef
collectOpportunities _ _ = []

------------------------------------------------------------------------
-- Step 1 (continued): candidate filter -- is the parameter that
-- received a KnownClosure actually used only via `apply` in `g`'s own
-- body? If not, cloning buys nothing (Step 3 would just discard the
-- clone anyway, but there's no point building and re-folding it first).
------------------------------------------------------------------------

||| If `e` is exactly a `missing`-long apply chain rooted at `v`,
||| returns the `missing` arguments actually applied, in call order --
||| `RApp`'s own two operands are bare `RCLocal`s (never a nested
||| `RApp`), so a curried `v a1 a2` (two more args needed) ANF-
||| normalizes to `RLet t (RApp v a1) (RApp t a2)`, not one node; this
||| chases that shape level by level, `v` at the first apply, each
||| freshly-bound intermediate result at the next. The *last* apply in
||| the chain is allowed to be a bare tail expression (`RApp _ _ c a`,
||| nothing else -- the chain's own overall result *is* whatever
||| consumes it, one level further out, that this function itself never
||| looks at) instead of being wrapped in one more `RLet` of its own,
||| since nothing inside the chain needs to *name* that final result.
||| `Nothing` on any other shape -- no partial credit; a chain the fold
||| below any other node interrupts (another unrelated `RLet`, a case
||| split, ...) isn't specialized at all rather than partially.
chainArgs : RCLocal -> Nat -> RCExp -> Maybe (List RCLocal)
chainArgs v (S Z) (RApp _ _ c a) = if c == v then Just [a] else Nothing
chainArgs v (S k@(S _)) (RLet _ t _ (RApp _ _ c a) cont) =
    if c == v then (a ::) <$> chainArgs (RCLoc t) k cont else Nothing
chainArgs _ _ _ = Nothing

||| `True` iff a `missing`-long `chainArgs` match for `v` occurs
||| somewhere in `e` -- tried at every node on the way down (a chain's
||| own root can be any sub-expression, not just `e`'s own top level --
||| `go`'s own real body, for instance, roots one inside the *value* of
||| an outer, unrelated `RLet`), falling back to ordinary structural
||| recursion wherever it doesn't match. Same "explicit case per
||| constructor that can hold a nested `RCExp`, `False` for the rest"
||| shape as `collectOpportunities` above, for the same reason (this
||| pass's own input never contains anything past Phase 1).
chainOccursIn : RCLocal -> Nat -> RCExp -> Bool
chainOccursIn v missing e = isJust (chainArgs v missing e) || goInto e
  where
    goInto : RCExp -> Bool
    goInto (RLet _ _ _ value body) = chainOccursIn v missing value || chainOccursIn v missing body
    goInto (RCmpCase _ _ _ _ t f) = chainOccursIn v missing t || chainOccursIn v missing f
    goInto (RConCase _ _ alts mDef) =
        any (\(MkRConAlt _ _ _ _ body) => chainOccursIn v missing body) alts
        || maybe False (chainOccursIn v missing) mDef
    goInto (RConstCase _ _ alts mDef) =
        any (\(MkRConstAlt _ body) => chainOccursIn v missing body) alts
        || maybe False (chainOccursIn v missing) mDef
    goInto _ = False

||| `xs !! n`, `Maybe`-total.
nthArg : Nat -> List a -> Maybe a
nthArg _ [] = Nothing
nthArg Z (x :: _) = Just x
nthArg (S k) (_ :: xs) = nthArg k xs

||| How many of `v`'s occurrences in `e` are specifically argument
||| `argPos` of a *self*-recursive call to `callee` (i.e. `g` calling
||| itself, unchanged, at the very position `v` itself occupies in
||| `g`'s own signature) -- `go (x :: xs) f = f x >> go xs f`'s own
||| trailing `go xs f` is exactly this shape, and it's *expected*, not
||| disqualifying: every ordinary structurally-recursive traversal
||| threads its own closure argument through to the next call
||| unchanged. `paramLooksSpecializable` below credits each one of
||| these against `countUsesR`'s own total instead of requiring
||| `v` to occur exactly once outright -- without this, no genuinely
||| recursive `go`-shaped function (this module's own motivating case)
||| would ever qualify at all, confirmed the hard way: an earlier
||| version requiring a bare single occurrence rejected `go` itself,
||| the design doc's own worked example, outright.
selfPassthroughOccurrences : RCLocal -> (callee : Name) -> (argPos : Nat) -> RCExp -> Nat
selfPassthroughOccurrences v callee argPos (RAppName _ _ n args) =
    if n == callee && nthArg argPos args == Just v then 1 else 0
selfPassthroughOccurrences v callee argPos (RLet _ _ _ value body) =
    selfPassthroughOccurrences v callee argPos value + selfPassthroughOccurrences v callee argPos body
selfPassthroughOccurrences v callee argPos (RCmpCase _ _ _ _ t f) =
    selfPassthroughOccurrences v callee argPos t + selfPassthroughOccurrences v callee argPos f
selfPassthroughOccurrences v callee argPos (RConCase _ _ alts mDef) =
    sum (map (\(MkRConAlt _ _ _ _ body) => selfPassthroughOccurrences v callee argPos body) alts)
    + maybe 0 (selfPassthroughOccurrences v callee argPos) mDef
selfPassthroughOccurrences v callee argPos (RConstCase _ _ alts mDef) =
    sum (map (\(MkRConstAlt _ body) => selfPassthroughOccurrences v callee argPos body) alts)
    + maybe 0 (selfPassthroughOccurrences v callee argPos) mDef
selfPassthroughOccurrences _ _ _ _ = 0

||| `True` iff `v`'s every occurrence in `e` is accounted for by
||| exactly one `missing`-long apply chain rooted at `v` plus zero or
||| more self-recursive passthrough calls (`selfPassthroughOccurrences`
||| above) -- the precondition `speculative-closure-specialization.md`'s
||| Step 1 names ("used only via apply inside g's own body"),
||| generalized both from a single `apply` to a full saturating chain
||| of them (`missing > 1`, see this module's own header doc comment)
||| and from "used only via apply" to "used only via apply, or passed
||| straight through to a recursive call" (`selfPassthroughOccurrences`'s
||| own doc comment).
paramLooksSpecializable : RCLocal -> Nat -> (callee : Name) -> (argPos : Nat) -> RCExp -> Bool
paramLooksSpecializable v missing callee argPos e =
    let uses = countUsesR v e
        passthrough = selfPassthroughOccurrences v callee argPos e
    in uses > passthrough && (uses `minus` passthrough) == 1 && chainOccursIn v missing e

------------------------------------------------------------------------
-- Step 2: speculative clone + rewrite, one attempt per distinct
-- (callee, argPos, target, missing) key -- `capturedArgs`' own values
-- are deliberately not part of that key (that's the whole point: two
-- call sites capturing different locals but naming the same target
-- both redirect to the one clone built for that target).
------------------------------------------------------------------------

||| Rewrites the `missing`-long apply chain rooted at `paramVar`
||| (`chainArgs`'s own doc comment) into a direct call to `targetName`,
||| fed `capturedParams` (the clone's own new leading parameters
||| standing in for whatever `target`'s own `RUnderApp` used to
||| capture) followed by every argument the chain applied, in order.
||| Tries `chainArgs` at each node on the way down, same "whole-subtree
||| replacement, else recurse structurally" shape `chainOccursIn` uses
||| to *find* the chain -- this is that same walk, but rewriting instead
||| of just checking. Same "explicit case per constructor holding a
||| nested `RCExp`, `e => e` for the rest" shape as
||| `collectOpportunities`/`chainOccursIn` above, for the same "Phase 1
||| input only" reason.
rewriteApply : (paramVar : Int) -> (targetName : Name) -> (missing : Nat) -> (capturedParams : List Int) -> RCExp -> RCExp
rewriteApply paramVar targetName missing capturedParams = go
  where
    mutual
      go : RCExp -> RCExp
      go e =
          case chainArgs (RCLoc paramVar) missing e of
               Just args => RAppName EmptyFC Nothing targetName (map RCLoc capturedParams ++ args)
               Nothing => goInto e

      goInto : RCExp -> RCExp
      goInto (RLet fc var rep value body) = RLet fc var rep (go value) (go body)
      goInto (RCmpCase fc op args postDrop t f) = RCmpCase fc op args postDrop (go t) (go f)
      goInto (RConCase fc sc alts mDef) = RConCase fc sc (map goAlt alts) (map go mDef)
      goInto (RConstCase fc sc alts mDef) = RConstCase fc sc (map goConstAlt alts) (map go mDef)
      goInto e = e

      goAlt : RConAlt -> RConAlt
      goAlt (MkRConAlt n ci tag as body) = MkRConAlt n ci tag as (go body)

      goConstAlt : RConstAlt -> RConstAlt
      goConstAlt (MkRConstAlt c body) = MkRConstAlt c (go body)

||| The largest `Int` var id bound anywhere in `e` -- `RLet`'s own
||| `var` and every `RConAlt`'s own binder `args`, the only two node
||| shapes that ever introduce a *new* id (`Compiler.RC2.RC`'s own
||| `normalizeDef` assigns every one of a definition's own ids exactly
||| once, monotonically, via `nextVarId`, so a definition's own ids are
||| exactly the range `[0 .. maxVarInBody]`, no gaps). `-1` for a body
||| that binds nothing (e.g. a bare `RV`/`RCrash`/... leaf) -- always
||| one less than the lowest id `normalizeDef` could ever hand out, so
||| `maxVarInBody body + 1` is a safe "definitely unused in this body"
||| id to start allocating fresh ones from regardless. Needed because
||| `buildClone`'s own new captured-value parameters must never collide
||| with an id `g`'s own body already uses -- allocating them from this
||| module's own whole-program `FreshId` ref instead (a counter with no
||| relationship at all to any one definition's own numbering, which
||| itself restarts at 0 per definition) would very likely collide,
||| confirmed the hard way: a real "redeclared with a different kind of
||| symbol" C compile error on `var_1` the first time this was tried
||| with a plain `freshId`-only allocation.
maxVarInBody : List (Int, Rep) -> RCExp -> Int
maxVarInBody args body = max (foldl max (-1) (map fst args)) (go body)
  where
    mutual
      go : RCExp -> Int
      go (RLet _ var _ value body') = max var (max (go value) (go body'))
      go (RCmpCase _ _ _ _ t f) = max (go t) (go f)
      go (RConCase _ _ alts mDef) = max (foldl max (-1) (map goAlt alts)) (maybe (-1) go mDef)
      go (RConstCase _ _ alts mDef) = max (foldl max (-1) (map goConstAlt alts)) (maybe (-1) go mDef)
      go _ = -1

      goAlt : RConAlt -> Int
      goAlt (MkRConAlt _ _ _ as body') = max (foldl max (-1) as) (go body')

      goConstAlt : RConstAlt -> Int
      goConstAlt (MkRConstAlt _ body') = go body'

||| `n` fresh, sequential, definitely-unused ids starting right after
||| `base` (`maxVarInBody`'s own return value) -- `[]` for `n = Z`.
||| Deliberately not `[1 .. n]`-shaped range syntax: confirmed directly
||| that Idris2's own `Enum Nat` doesn't treat `[1 .. 0]` as empty
||| (`[1 .. 0] = [1, 0]`, two elements) the way a Haskell-trained
||| instinct expects, which silently manufactured two spurious captured
||| parameters every time `capturedCount` was genuinely 0 before this
||| was caught by an actual C compile failure.
freshIdsFrom : Int -> Nat -> List Int
freshIdsFrom base Z = []
freshIdsFrom base (S k) = (base + 1) :: freshIdsFrom (base + 1) k

||| Rewrites every self-recursive call to `callee` (`g` calling itself)
||| that passes `paramVar` unchanged at `argPos` -- exactly the
||| `selfPassthroughOccurrences` shape -- into a call to `cloneName`
||| instead, splicing `capturedParams` into that same position (the
||| clone's own reduced signature no longer has a slot for the original
||| closure argument at all). Without this, a genuinely recursive `g`
||| (`go`'s own trailing `go xs f`, this module's own motivating shape)
||| would keep recursing into the generic, un-specialized `g` forever
||| after the very first call, specializing nothing beyond that single
||| outermost invocation -- confirmed the hard way, the same way
||| `selfPassthroughOccurrences`'s own doc comment describes for the
||| candidate-detection half of this same problem.
rewriteSelfCall : (callee : Name) -> (argPos : Nat) -> (paramVar : Int) -> (cloneName : Name) -> (capturedParams : List Int) -> RCExp -> RCExp
rewriteSelfCall callee argPos paramVar cloneName capturedParams = go
  where
    go : RCExp -> RCExp
    go (RAppName fc lazy n args) =
        if n == callee && nthArg argPos args == Just (RCLoc paramVar)
           then case splitAt argPos args of
                     (before, _ :: after) => RAppName fc lazy cloneName (before ++ map RCLoc capturedParams ++ after)
                     _ => RAppName fc lazy n args
           else RAppName fc lazy n args
    go (RLet fc var rep value body) = RLet fc var rep (go value) (go body)
    go (RCmpCase fc op args postDrop t f) = RCmpCase fc op args postDrop (go t) (go f)
    go (RConCase fc sc alts mDef) = RConCase fc sc (map goAlt alts) (map go mDef)
      where
        goAlt : RConAlt -> RConAlt
        goAlt (MkRConAlt n ci tag as body) = MkRConAlt n ci tag as (go body)
    go (RConstCase fc sc alts mDef) = RConstCase fc sc (map goAlt alts) (map go mDef)
      where
        goAlt : RConstAlt -> RConstAlt
        goAlt (MkRConstAlt c body) = MkRConstAlt c (go body)
    go e = e

||| Builds one specialized clone of `g` (`callee`; `paramVar`: the
||| `Int` id of `g`'s own closure parameter, at whatever position
||| `argPos` named) for one `(targetName, missing, capturedCount)`
||| triple. `capturedCount` is taken from one real witnessing call
||| site's own `capturedArgs` length by `applySpecClosure` below --
||| assumed consistent across every call site sharing this key, true by
||| construction (same `target` name/arity everywhere it's ever
||| referenced). Returns the clone's own fresh name and its `RCDef`;
||| the clone is *not* re-folded here -- `applySpecClosure` does that
||| once, after this returns, so `buildClone` itself stays a pure,
||| `FreshId`-only construction step for the clone's own *name* -- its
||| new parameters' own ids come from `maxVarInBody` above instead, not
||| `FreshId` (see that function's own doc comment for why).
buildClone : {auto fr : Ref FreshId Int}
          -> (callee : Name) -> (argPos : Nat)
          -> (paramVar : Int) -> (targetName : Name) -> (missing : Nat) -> (capturedCount : Nat)
          -> (args : List (Int, Rep)) -> (retRep : Rep) -> (body : RCExp)
          -> Core (Name, RCDef)
buildClone callee argPos paramVar targetName missing capturedCount args retRep body = do
    cloneId <- freshId
    let base = maxVarInBody args body
    -- NOT `[1 .. capturedCount]` -- Idris2's own `Enum Nat` range
    -- syntax is *not* empty for `[1 .. 0]` (confirmed directly:
    -- `[1 .. 0] = [1, 0]`, two elements, not zero), so that produced
    -- two spurious captured parameters whenever `capturedCount` was
    -- genuinely 0 -- a real bug caught by an actual C compile failure
    -- (a generated clone declared with more parameters than its own
    -- call sites ever passed).
    let capturedParams = freshIdsFrom base capturedCount
    let cloneName = MN "rc2_specClosure" cloneId
    let args' = concatMap (\(i, r) => if i == paramVar
                                          then map (\p => (p, RBoxed)) capturedParams
                                          else [(i, r)]) args
    let body' = rewriteSelfCall callee argPos paramVar cloneName capturedParams
                    (rewriteApply paramVar targetName missing capturedParams body)
    pure (cloneName, MkRCFun args' retRep False body')

------------------------------------------------------------------------
-- Step 3: profitability check + call-site redirection
------------------------------------------------------------------------

||| `True` iff `e` still references `paramVar` anywhere -- if so, the
||| specialization didn't actually remove the indirection it was built
||| to remove (the closure escaped somewhere the fold couldn't reach:
||| stored in a data structure, returned, applied inside a branch the
||| fold didn't resolve, ...), and the clone bought nothing. Plain
||| `countUsesR` is enough here (unlike `paramLooksSpecializable`'s own
||| more careful chain-aware check) -- Step 2's `rewriteApply` already
||| removed `paramVar`'s own one occurrence *if* the chain it rooted
||| survived folding intact, so any occurrence still present after a
||| fresh `foldConstDef` pass, in whatever shape it now takes, means the
||| specialization didn't fully take -- the actual profitability gate
||| `speculative-closure-specialization.md`'s Step 3 calls for.
stillAppliesParam : Int -> RCExp -> Bool
stillAppliesParam paramVar e = countUsesR (RCLoc paramVar) e > 0

||| Every call site `RAppName`-shaped and matching `(callee, argPos)`,
||| redirected to `cloneName` -- the argument at `argPos` (that call
||| site's own capture list, per its own `KnownClosure`) is spliced in
||| in its place, so the rewritten call's own arity matches the clone's
||| reduced signature. Only ever called with `(callee, argPos)` keys
||| Step 2 actually kept a clone for -- a call site whose own
||| `KnownClosure` doesn't share the *specific* `target` this clone was
||| built for is left untouched (it keeps calling the generic, un-cloned
||| `g`, exactly `speculative-closure-specialization.md`'s Step 2's own
||| memoization-per-target design).
redirectCallSites : (callee : Name) -> (argPos : Nat) -> (target : Name) -> (cloneName : Name) -> RCExp -> RCExp
redirectCallSites callee argPos target cloneName = goBound empty
  where
    goBound : Bound -> RCExp -> RCExp
    goBound bound (RLet fc var rep value body) =
        let value' = goBound bound value
            bound' = case value of
                          RUnderApp _ n missing capturedArgs =>
                              insert var (MkKnownClosure n missing capturedArgs) bound
                          _ => bound
        in RLet fc var rep value' (goBound bound' body)
    goBound bound (RAppName fc lazy n args) =
        if n == callee
           then case splitAt argPos args of
                     (before, a :: after) =>
                         case lookupKnown bound a of
                              Just (MkKnownClosure t _ capturedArgs) =>
                                  if t == target
                                     then RAppName fc lazy cloneName (before ++ capturedArgs ++ after)
                                     else RAppName fc lazy n args
                              Nothing => RAppName fc lazy n args
                     _ => RAppName fc lazy n args
           else RAppName fc lazy n args
    goBound bound (RCmpCase fc op cargs postDrop t f) = RCmpCase fc op cargs postDrop (goBound bound t) (goBound bound f)
    goBound bound (RConCase fc sc alts mDef) = RConCase fc sc (map (goAlt bound) alts) (map (goBound bound) mDef)
      where
        goAlt : Bound -> RConAlt -> RConAlt
        goAlt b (MkRConAlt n ci tag as body) = MkRConAlt n ci tag as (goBound b body)
    goBound bound (RConstCase fc sc alts mDef) = RConstCase fc sc (map (goAlt bound) alts) (map (goBound bound) mDef)
      where
        goAlt : Bound -> RConstAlt -> RConstAlt
        goAlt b (MkRConstAlt c body) = MkRConstAlt c (goBound b body)
    goBound _ e = e

------------------------------------------------------------------------
-- Whole-program entry point
------------------------------------------------------------------------

||| One round of speculative closure-argument specialization -- see
||| this module's own header doc comment for the full design/scope.
|||
||| Written as a single, non-iterating round *by explicit request*: a
||| kept clone's own body can, in principle, expose a fresh
||| specialization opportunity of its own (a clone calling another
||| generic higher-order function with a now-constant closure argument
||| it didn't have before), the same way `Compiler.RC2.RC2`'s own
||| `foldConstProgram` re-runs `ConstFold` to a fixpoint because one
||| CAF's own fold can unblock another. Not attempted yet -- run this
||| function again on its own output (`applySpecClosure
||| !(applySpecClosure defs)`, or a small `go fuel defs` loop mirroring
||| `foldConstProgram`'s own shape) once real evidence calls for it;
||| nothing about this function's own signature or the `FreshId` ref it
||| allocates needs to change to support that later.
export
applySpecClosure : List (Name, RCDef) -> Core (List (Name, RCDef))
applySpecClosure defs = do
    _ <- newRef FreshId 0
    let defOf : SortedMap Name RCDef := SortedMap.fromList defs
    let opportunities : List Opportunity :=
            concatMap (\(_, d) => case d of
                                        MkRCFun _ _ _ body => collectOpportunities empty body
                                        _ => [])
                      defs
    -- `missing` is part of the key, not just `target` -- the same
    -- top-level function captured at two *different* under-application
    -- depths (e.g. `RUnderApp target 1 [a,b,c]` vs. `RUnderApp target 2
    -- [a,b]`) needs two different clones, one per depth, since
    -- `capturedCount`/the rewritten chain length differ between them.
    let byKey : SortedMap (Name, Nat, Name, Nat) (List Opportunity) :=
            foldl (\acc, opp =>
                      let key = (opp.callee, opp.argPos, opp.closure.target, opp.closure.missing)
                      in insertWith (++) key [opp] acc)
                  (the (SortedMap (Name, Nat, Name, Nat) (List Opportunity)) empty) opportunities
    goKeys defOf defs (SortedMap.toList byKey)
  where
    ||| `paramVar`, if `g`'s own `args` list names one at `argPos` and
    ||| that parameter passes `paramLooksSpecializable` for `missing`;
    ||| `Nothing` otherwise (out-of-range position, or the parameter is
    ||| used for something other than a plain `missing`-long apply
    ||| chain, plus any number of self-recursive passthrough calls).
    specializableParam : (callee : Name) -> Nat -> Nat -> RCDef -> Maybe Int
    specializableParam callee argPos missing (MkRCFun args _ _ body) =
        case nthArg argPos args of
             Nothing => Nothing
             Just (i, _) => if paramLooksSpecializable (RCLoc i) missing callee argPos body then Just i else Nothing
    specializableParam _ _ _ _ = Nothing

    rebuildCafTable : List (Name, RCDef) -> CafTable
    rebuildCafTable = foldl (\tbl, (n, d) => maybe tbl (\v => insert n v tbl) (cafValueOf d)) empty

    redirectAll : Name -> Nat -> Name -> Name -> List (Name, RCDef) -> List (Name, RCDef)
    redirectAll callee argPos target cloneName defs' =
        map (\(n, d) => (n, case d of
                                 MkRCFun a r w body => MkRCFun a r w (redirectCallSites callee argPos target cloneName body)
                                 d' => d'))
            defs'

    tryOneKey : {auto fr : Ref FreshId Int} -> SortedMap Name RCDef -> Name -> Nat -> Name -> Nat -> List Opportunity -> List (Name, RCDef) -> Core (List (Name, RCDef))
    tryOneKey defOf callee argPos target missing opps accDefs =
        case lookup callee defOf of
             Just gDef@(MkRCFun args retRep _ body) =>
                 case specializableParam callee argPos missing gDef of
                      Nothing => pure accDefs
                      Just paramVar =>
                          case opps of
                               [] => pure accDefs
                               (rep :: _) => do
                                   let capturedCount = length rep.closure.capturedArgs
                                   (cloneName, cloneDef) <- buildClone callee argPos paramVar target missing capturedCount args retRep body
                                   let cloneDef' = foldConstDef (rebuildCafTable accDefs) cloneDef
                                   case cloneDef' of
                                        MkRCFun _ _ _ foldedBody =>
                                            if stillAppliesParam paramVar foldedBody
                                               then pure accDefs
                                               else pure $ redirectAll callee argPos target cloneName
                                                             ((cloneName, cloneDef') :: accDefs)
                                        _ => pure accDefs
             _ => pure accDefs

    ||| `Core` (`Core.Core`) has no `Monad` instance of its own (this
    ||| project's own hand-rolled effect monad, resolved via its own
    ||| `>>=` rather than the standard interface hierarchy), so
    ||| `Data.List`'s `foldlM` doesn't apply here -- a small manual
    ||| left fold over the discovered keys instead, same shape.
    goKeys : {auto fr : Ref FreshId Int}
          -> SortedMap Name RCDef -> List (Name, RCDef) -> List ((Name, Nat, Name, Nat), List Opportunity) -> Core (List (Name, RCDef))
    goKeys _ accDefs [] = pure accDefs
    goKeys defOf accDefs (((callee, argPos, target, missing), opps) :: rest) = do
        accDefs' <- tryOneKey defOf callee argPos target missing opps accDefs
        goKeys defOf accDefs' rest
