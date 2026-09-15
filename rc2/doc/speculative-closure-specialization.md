# Speculative, profitability-gated closure-argument specialization: investigated, designed, implemented

This document records a design considered as "Level 1" of the closure-
specialization idea `rc2/doc/loop-in-case-sinking.md`'s own "A related,
larger idea" section first raised (resolving a higher-order function's
own closure-argument `apply` to a direct named `call`, without
necessarily inlining the target's body). It also records a full
investigation of whether upstream Idris2's own `%spec` mechanism could
provide this for free, and why it can't for the concrete case that
motivated it. **Status: implemented, as `Compiler.RC2.SpecClosure`**
(disable with `--directive nospecclosure`) -- see "Implementation
notes" below for exactly what shipped, where it deviates from the
paper design this document otherwise still describes accurately, and
what verification found.

## Motivation

`idris2-missing-containers`' `Main.idr` has its own small `foldl`-
shaped traversal:

```idris
go : List String -> (String -> IO ()) -> IO ()
go [] _ = pure ()
go (x::xs) f = f x >> go xs f
```

`--directive dumprcexpr` confirms `Compiler.RC2.Loop` correctly turns
this into a real `RLoop`, and confirms `go` is the actual driver behind
both the `write` and `read` phases of `benchmarkHashMap` -- the two
phases this project's own profiling (`rc2/BENCHMARKS.md`) already found
dominating this benchmark's wall time. Every iteration of `go`'s own
loop does `apply v1 v3` -- a boxed, indirect closure dispatch
(`idris2rc2_applyClosure`) -- to process one element, even though, at
each of `go`'s own two real call sites in this program, the closure
handed to it is *not* an arbitrary runtime value: it's always the exact
same one specific top-level callback (the `IOHashMap.write`-driving one
for the `write` phase, a different `IOHashMap.read`-driving one for the
`read` phase).

If `go` could be cloned once per distinct closure target actually
observed, with that one clone's own `apply v1 v3` resolved to a direct,
named `call` to the known target, the per-iteration dispatch overhead
this session's own earlier investigation attributed to boxed closure/
interface-dictionary dispatch (`TODO.md`'s "Performance: interface-
dictionary method dispatch stays boxed..." entry, and this session's own
`HasIO`-polymorphism findings) would apply here too, for an ordinary
higher-order function argument, not just an interface method.

## Why not just use upstream `%spec`: full investigation

Idris2's own partial evaluator (`TTImp.PartialEval`, the `%spec`
pragma) was investigated as a way to get this for free, at the
frontend level, with no rc2 changes at all. Two real preconditions were
found empirically (via minimal repros, each confirmed with `--log
specialise:5` and by inspecting generated C), one of which was missed
on the first pass of this investigation and corrected mid-session:

1. **The specialized parameter must be explicitly named in the type
   signature itself**, not just in the defining clause. `%spec f` on
   `apply1 : (Int -> Int) -> Int -> Int` (parameter left anonymous in
   the signature, named only as `f` in the clause `apply1 f x = f x`)
   silently produces *zero* log output and *zero* specialized clone --
   not a logged failure, just complete silence, because `specArgs
   gdef` (the set of positions `%spec` actually marks) never gets
   populated for an unnamed signature position at all. Renaming to
   `apply1 : (f : Int -> Int) -> Int -> Int` with the exact same
   `%spec f` line immediately works, confirmed by `--log specialise:5`
   showing `New RHS: (prim__add_Int x[0] 1)` -- the specialized clone's
   entire body, target function included, fully unfolded to a bare
   primitive op with zero remaining indirection. This is a real,
   confirmed capability of `%spec`: it *can* specialize through an
   ordinary function-typed (closure) argument, not just an interface
   dictionary or a plain data value -- the earlier conclusion in this
   investigation's own first pass ("function-typed arguments aren't
   supported") was wrong, and is corrected here.
2. **The value passed at the call site must still be a genuinely closed
   term** (`PartialEval.idr`'s own `concrete = shrink tm none`, i.e. no
   free variables at all) -- unaffected by the naming fix above, and
   the actual reason this doesn't rescue `go`'s own real call sites.
   Confirmed with a second repro: `apply1 (addBase base) 5` inside a
   function `test base = ...`, where `addBase base` is a partial
   application capturing the *local* parameter `base` -- even with the
   signature-naming fix applied, this produces the identical silent
   zero-log-output non-attempt. `go`'s own two real call sites in
   `idris2-missing-containers` are exactly this shape: `go words $
   ignore . pure . hash h` (`h` is `benchmarkHash`'s own parameter) and
   `go dict $ \x => do ... hm ...` / `go words $ ignore . read hm`
   (`hm` is a local `let`-bound value in `benchmarkHashMap`) -- neither
   is a closed term, even though the underlying *code* each one
   ultimately runs is fixed and known at each call site. `%spec`'s own
   closedness requirement has no way to express "this closure's
   underlying code pointer is invariant even though its captured
   environment differs" -- a strictly weaker, but still exploitable,
   property that plain closedness doesn't capture.

**Separately, and orthogonal to both preconditions above**: upstream's
own `mkSpecDef` has no profitability gate at all. Its only fallback path
is for a genuine *elaboration error* during specialization (`handleUnify`'s
own error handler, `logC "specialise.fail"`, discarding the attempt and
reusing the original call) -- there is no check anywhere for "the
specialization succeeded (produced a real clone) but didn't actually
collapse to anything smaller or less indirect than the generic version."
Every call site whose specialized argument happens to be closed gets a
full clone unconditionally. This matches a real, previously-hit problem:
unrestricted specialization has caused real code-size blowup before, with
no built-in mechanism to hold it back. This is the second half of this
document's own motivation, independent of whether `%spec` could even
reach `go`'s own call sites at all.

## The proposed rc2-native design

Given `%spec` can't reach the motivating case (closedness) and has no
profitability gate even where it can fire, this section designs an
rc2-side mechanism operating on `RCExp` after the point `Compiler.RC2.ConstFold`
already runs, reusing the same "is this closure argument a compile-time
constant" detection `RCConstClosure` (`rc2/doc/const-closure-fold.md`)
already provides -- which captures exactly the "code pointer invariant,
environment may differ" property `%spec`'s own closedness check cannot,
since `ConstFold`/`Inline`'s own reasoning already operates after
lambda-lifting, on the *lifted* closure value itself (`partial
Main.{benchmarkHashMap:19} missing=2 [v85, v80]`), not the pre-lift
surface term with its free-variable captures.

### 1. Candidate detection

For each call site of a function `g` (`go` in the motivating case) where
one of `g`'s own parameters is used only via `apply` inside `g`'s own
body, check whether the *argument* supplied at this call site is --
after `ConstFold` -- provably always the same named top-level function,
independent of which free variables it happens to close over. This is
weaker than full closedness: `partial Main.{benchmarkHashMap:19}
missing=2 [v85, v80]` and `partial Main.{benchmarkHashMap:19} missing=2
[v200, v201]` (two different call sites capturing *different* locals
but naming the *same* underlying function) both count as "the same
target" for this purpose, even though neither is a closed term in
`%spec`'s own sense. Collect the *set* of distinct targets `g` is ever
called with, program-wide.

### 2. Speculative clone + re-fold, one attempt per distinct target

For each distinct target found in step 1 (memoized -- a given `(g,
target)` pair is only ever attempted once, however many call sites
share it, bounding the total number of clones to the number of
*distinct* targets actually observed, not the number of call sites):

- Clone `g`'s own body, rewriting every `apply` of the specialized
  parameter into a direct `call target [...]` (with `target`'s own
  captured/free arguments threaded through as extra parameters on the
  clone, the same shape `Compiler.RC2.Inline`'s own existing splicing
  machinery already handles for an ordinary call-free callee).
- Re-run `ConstFold`/`Inline` on *just this clone* (not the whole
  program again) to let any further folding this direct call newly
  exposes actually happen -- e.g. if `target` is itself small and
  call-free, `Inline`'s existing Criterion A can now reach it, since
  the call is no longer hidden behind `apply`.

### 3. Profitability check -- the actual gate

Walk the *folded* clone's own body and check: does it still contain any
`apply` node targeting the specialized parameter (or, transitively, the
same class of boxed dispatch the specialization was trying to remove)?

- **No remaining `apply` of that kind** -- the specialization actually
  achieved what it set out to (the `apply1`/`inc` repro's own
  `New RHS: (prim__add_Int x[0] 1)` is the ideal instance of this:
  every trace of indirection gone). **Keep the clone**; redirect every
  call site sharing this `(g, target)` pair to it.
- **Still present** -- the closure escaped somewhere the fold couldn't
  reach (stored in a data structure, returned, applied inside a branch
  the fold didn't resolve, etc.) -- the clone bought nothing over the
  generic version, just a second copy of the same indirection.
  **Discard the clone**; every call site keeps calling the original,
  generic `g`.

This is deliberately a **structural**, not a size-threshold, check --
it answers "did this remove the exact indirection it was built to
remove," not the fuzzier "did this come out smaller," which would risk
rejecting a genuinely good but textually larger result or accepting a
small but useless one. It's also cheap to compute: a single linear walk
of the already-folded clone, no separate cost model needed.

## Why this is architecturally new for rc2

Every existing rc2 pass (`Inline`'s Criterion A, `ConAltNative`,
`ConstFold` itself, the sinking transform in `loop-in-case-sinking.md`)
decides eligibility *before* transforming, from the untransformed
input's own shape -- a pure, one-directional "check, then rewrite"
pipeline stage. This design instead transforms *speculatively* first
and decides based on the *result* -- a "try, then keep or discard"
shape with no existing precedent in `Compiler.RC2`. Not a soundness
concern (a discarded clone is simply never referenced by anything, so
it costs nothing at runtime and can be dropped by `Compiler.RC2.DeadCode`
same as any other unreferenced definition) -- but worth naming
explicitly as a new kind of pass architecture before building it, not
a small extension of an existing one.

## Relationship to `loop-in-case-sinking.md`

That document's own "related, larger idea" section considered inlining
a small loop-only function into an already-looping caller, and found it
needs genuine nested-loop support (`Compiler.RC2.DualABI`'s
`loopContinueNativeReads` becoming a stack) whenever the specialized-
and-inlined target itself turns out to be (or contain) a loop. This
document's own design is deliberately narrower and avoids that
dependency entirely: step 2 above resolves `apply` to a direct `call`
and opportunistically re-folds via `Inline`'s own existing (unchanged)
Criterion A -- it never forces inlining of a target that Criterion A
itself would reject (e.g. because the target contains its own further
calls, or is itself a loop). A target that happens to be a loop simply
stays a direct `call` after step 2 (no `apply`, already a real win) and
is never spliced into the caller's own loop body -- so the profitability
check in step 3 above passes on its own terms (no more `apply`) without
ever needing to inline the target's body or produce nested `RLoop`
nodes. **This design needs no nested-loop support at all**, unlike the
"related, larger idea" it grew out of.

## Implementation notes: what shipped, and where it deviates

`Compiler.RC2.SpecClosure` (own module doc comment has the fuller
version of this) implements Steps 1-3 above essentially as designed,
running once between `Compiler.RC2.RC2`'s own `foldConstProgram` and
`insertMemoize`. Two real gaps surfaced during implementation, both
required for `go` itself -- this document's own motivating case -- to
specialize at all, so neither is optional polish:

- **`missing > 1` needed its own chain-walking detection/rewrite**,
  not just a single `RApp` node. `RApp`'s own two operands are bare
  `RCLocal`s, never a nested `RApp`, so a curried `f a1 a2` (two more
  args needed) ANF-normalizes to `RLet tmp (RApp f a1) (RApp tmp a2)`,
  not one node. This matters more than it might look: an ordinary
  `String -> IO ()` callback -- exactly `go`'s own shape -- lowers to
  `missing = 2` here (the real argument, then the hidden `%World`
  token IO's own calling convention threads through), never
  `missing = 1`. A first cut of this module that only handled
  `missing == 1` compiled fine and ran correctly on everything, but
  silently never fired on `go` itself. `chainArgs`/`chainOccursIn` in
  `SpecClosure.idr` do this walk; only the exact shape (each apply's
  result immediately feeding the next, nothing else interposed) is
  recognized -- a chain interrupted by anything else is left alone,
  conservatively.
- **A parameter passed straight through to a self-recursive call
  needed explicit handling.** `go`'s own trailing `go xs f` is exactly
  this: the closure parameter isn't only applied, it's also threaded
  unchanged into the next iteration -- the ordinary shape for any
  structurally-recursive traversal, not a corner case. Without
  redirecting that recursive call to the clone too
  (`rewriteSelfCall`/`selfPassthroughOccurrences`), only the very first
  element of any list would ever get specialized, since every
  subsequent iteration would still recurse into the generic,
  un-cloned `g`.

**Not implemented**: re-running `Inline` on a clone, the other half of
Step 2. `Compiler.RC2.Inline` is a whole-program `Lifted`-to-`Lifted`
pass that already ran once, before this pipeline stage, at the
pre-RCExp level -- re-invoking it on a single already-built RCExp
clone isn't something its current architecture supports (this is the
"Open questions" section's own "interacts with `Compiler.RC2.Inline`'s
own existing pass" question below, still unresolved). Only
`Compiler.RC2.ConstFold`'s `foldConstDef` is re-run on a clone here. A
`target` that's itself small and call-free is therefore not
opportunistically inlined into the clone -- it stays a real direct
call, which is still the win Step 3 checks for, just not the
additional one the paper design's own Step 2 also described.

**Verification**: a hand-written `go`-shaped repro (two call sites,
two distinct captured-closure targets, missing = 2 throughout)
specializes correctly under both `--directive noloop` and the default
pipeline -- `apply` fully resolved to a direct call, the self-
recursive call redirected to the clone, the generic `go` itself fully
dead-code-eliminated, correct program output. `rc2/tests/verify.sh`'s
full suite (85 tests + valgrind) passes; `refc-suite`'s own
`callingConvention` test needed its golden C output regenerated, not
because of any behavior change in the code it exercises, but because
this pass also universally specializes `PrimIO.unsafePerformIO`'s own
boilerplate `apply` (a real, if incidental, additional case that
matches the same shape), which shifts unrelated `tmp_N` numbering
elsewhere in the generated file. Against a real workload
(`idris2-missing-containers`' own `benchmarkHashMap`, this document's
own motivating benchmark), no measurable wall-time improvement (12.04s
vs. 12.09s, within noise) -- consistent with `rc2/BENCHMARKS.md`'s own
prior finding (a separate investigation, made before this pass
existed) that this specific workload's dominant costs are
interface-dispatched hashing and `IOHashMap`'s own `IORef`/list-
traversal write phase, neither of which is the "closure passed as an
ordinary function argument" shape this pass targets. The design's own
reasoning and the win it targets are still real -- `go` itself
specializes exactly as designed -- this particular external workload
just doesn't happen to spend its time there.

## Internal structure (`SpecClosure.idr`)

The module's own doc comments are deliberately short pointers back to
this section now -- this is the one place the reasoning lives.

**Records.** `KnownClosure` (`target`/`missing`/`capturedArgs`) mirrors
one `RUnderApp`'s own three fields -- `target`/`missing` are the part
that must agree for two call sites to count as "the same target";
`capturedArgs` is the per-call-site values, which vary freely (the
`[v85,v80]` vs. `[v200,v201]` example above). `Opportunity` records one
call site's own `(callee, argPos, KnownClosure)`. `Bound` maps a live
`RCLocal`'s `Int` id to the `KnownClosure` it's known to hold, built
forward through a definition's own body and never popped: `normalizeDef`
assigns every id once, monotonically, per definition, so no id is ever
rebound within one definition's own body -- an entry inserted anywhere
stays correct for the rest of that body, nested case alternatives
included.

**Finding a known closure at a use site (`lookupKnown`).** Either
`RCLoc i` traced through `Bound` to an enclosing `RUnderApp` (the
general, non-zero-capture case), or a bare `RCConstClosure n missing`
sitting directly in the argument position, no `Bound` lookup needed --
this is what a *zero*-capture `RUnderApp` already becomes by the time
this pass runs: `ConstFold`'s own narrower constant-closure folding
(`rc2/doc/const-closure-fold.md`) already substitutes it at every use
site, leaving no `Bound` entry to trace back to. Confirmed the hard
way: this module's own motivating repro (`mkTarget prefix`, `prefix` a
string literal) takes exactly this path -- the literal folds away
first, and an earlier version of `lookupKnown` that only ever checked
`Bound` missed it entirely.

**Chain detection (`chainArgs`/`chainOccursIn`).** `RApp`'s own two
operands are bare `RCLocal`s, never a nested `RApp`, so a curried
`v a1 a2` (two more args needed) ANF-normalizes to `RLet t (RApp v a1)
(RApp t a2)`, not one node. `chainArgs` chases that shape level by
level -- `v` at the first apply, each fresh intermediate at the next --
allowing the *last* apply to be a bare tail expression instead of one
more `RLet` (nothing inside the chain needs to name the final result).
Only the exact shape matches; anything interposed (an unrelated `RLet`,
a case split, ...) leaves the whole chain unspecialized, deliberately,
rather than give partial credit. `chainOccursIn` tries `chainArgs` at
every node on the way down, since a chain's own root can be any
sub-expression -- `go`'s own real body roots one inside the *value* of
an outer, unrelated `RLet`.

**Self-recursive passthrough (`selfPassthroughOccurrences`,
`rewriteSelfCall`).** See "Implementation notes" above for why this
exists at all. `paramLooksSpecializable` credits each passthrough
occurrence against `countUsesR`'s own total instead of requiring the
parameter to occur exactly once outright. `rewriteSelfCall` then
redirects any such recursive call, in the built clone, to the clone
itself, splicing `capturedParams` into the position the original
closure argument used to occupy.

**Safe fresh ids (`maxVarInBody`, `freshIdsFrom`).** A clone's new
captured-value parameters must never collide with an id `g`'s own body
already uses. Allocating them from this module's own `FreshId` ref
doesn't work -- it has no relationship to any one definition's own
numbering (which itself restarts at 0 per definition, `normalizeDef`'s
own `nextVarId`), and collided in practice, confirmed as an actual
"redeclared with a different kind of symbol" C compile error the first
time this was tried. `maxVarInBody` instead finds the largest `Int`
already bound anywhere in `g`'s own body plus its own arguments, and
`freshIdsFrom` counts up from there. Two gotchas, both confirmed by
real compile failures rather than caught in review:
- `maxVarInBody` must count `RConAlt`/`RConstAlt`'s own pattern-binder
  ids too, not just `RLet`'s. It deliberately does *not* go through
  this module's shared `foldSubExprs` combinator (below) for its
  `RConCase`/`RConstCase` cases -- that generic per-child recursion has
  no hook for a constructor alt's own binder list, and silently
  dropping those ids reproduced the exact same class of id collision
  the paragraph above describes.
- `freshIdsFrom n` is deliberately not `[1 .. n]` range syntax:
  Idris2's own `Enum Nat` gives `[1 .. 0] = [1, 0]`, two elements, not
  `[]` -- which silently manufactured two spurious captured parameters
  every time the real capture count was 0, until an actual C compile
  failure (a clone declared with more parameters than any of its call
  sites ever passed) caught it.

**Shared structural recursion (`mapSubExprs`, `foldSubExprs`).** Every
walk in this module that isn't `maxVarInBody` recurses into exactly
`RLet`/`RCmpCase`/`RConCase`/`RConstCase` (the only constructors that
can hold a nested `RCExp` in this pass's strictly-pre-Phase-2 input --
no `RDup`/`RDrop`/`RFree`/`RReleaseReuse`/`RReuseOffer`, `RLoop`/
`RLoopContinue`, `RAppNameRep`/`RAppFFIInline`, or `RMemoize` can occur
here) the same way, once a node's own special case doesn't match.
`mapSubExprs f` rebuilds a node via `f` on each child (`RCExp ->
RCExp` rewrites); `foldSubExprs op z f` combines each child's `f`
result with `op`, `z` for a childless leaf (`RCExp -> a` walks). Six
near-identical hand-written copies of this collapsed into these two
combinators; `maxVarInBody` is the one function that can't use
`foldSubExprs`, per the gotcha above.

**Profitability + redirection (`stillAppliesParam`,
`redirectCallSites`, `buildClone`).** `stillAppliesParam` is Step 3's
own gate: a plain `countUsesR` check on the folded clone (unlike
`paramLooksSpecializable`'s own chain-aware count) is enough, since any
survival of the parameter after `rewriteApply` already tried to remove
its one occurrence means the specialization didn't fully take.
`redirectCallSites` retraces `Bound` the same way `collectOpportunities`
did, so it can tell which call sites share the *specific* target a kept
clone was built for -- a call site naming a different target for the
same `(callee, argPos)` is left calling the generic `g`, per the
per-target memoization design. `buildClone`'s own `capturedCount`
parameter is taken from one witnessing call site and assumed consistent
across every call site sharing its `(callee, argPos, target, missing)`
key, true by construction (the same `target` name/arity everywhere it's
referenced).

## Open questions / risks

- **Multiple specialized parameters on one function**: still open, not
  implemented. `go` only has one closure parameter; a function with
  several would need the candidate set in step 1 to be a set of
  *tuples* (one target per parameter), multiplying the number of
  distinct `(g, targets...)` clones attempted -- still bounded (by the
  product of each parameter's own distinct-target count, typically
  small), but not designed in detail here, and `SpecClosure.idr`'s
  actual implementation only ever specializes one parameter position
  at a time.
- **Where in the pipeline this runs**: resolved -- a new step, right
  after `foldConstProgram` and strictly before `insertMemoize`, *not* a
  refinement of `Inline` itself (`Inline` stayed completely untouched;
  see "Implementation notes" above for why re-running it on a clone
  isn't done).
- **Re-annotating a clone's own ownership**: resolved, and simpler than
  expected -- a kept clone is inserted into the same `List (Name,
  RCDef)` `toRCDefs` already threads through `annotate`/`Reuse`/
  `ConAltNative`/`Loop`/etc. afterward, so it gets exactly the same
  treatment as any other definition with no special-casing needed at
  all. `SpecClosure` itself never calls `annotate`.
- **Interaction with `DupMerge`/`Loop`**: resolved by the full
  `rc2/tests/verify.sh` suite passing (85 tests + valgrind, 0 leaks) --
  no conflict observed against the real pipeline order.
- **No profiled evidence yet that keeping this bounded (memoized per
  distinct target) actually avoids real-world blowup**: partially
  addressed -- `idris2-missing-containers`' own `benchmarkHashMap`
  compiles and runs correctly with this pass enabled, with no observed
  code-size or correctness issue, but its own workload doesn't happen
  to exercise a function called from *many* distinct closure targets,
  so the memoization bound's own behavior under real stress is still
  unmeasured. The synthetic stress case (a function called from many
  distinct closure targets) this entry originally called for hasn't
  been built.
- **Applied once per compile, not iterated to a fixpoint** (new, found
  during implementation, by explicit request): a kept clone's own body
  can, in principle, expose a fresh specialization opportunity of its
  own, the same way `foldConstProgram` re-runs `ConstFold` to a
  fixpoint because one CAF's own fold can unblock another. Not
  attempted -- `SpecClosure.idr`'s own `applySpecClosure` doc comment
  has the rationale and the (trivial) shape a later fixpoint wrapper
  would take.

## Files

- `rc2/src/Compiler/RC2/SpecClosure.idr` -- the actual implementation.
  Its own module doc comment covers everything in "Implementation
  notes" above in more detail, close to the code it describes.
- `rc2/doc/directives.md` -- `--directive nospecclosure`, this pass's
  own disable flag.
- `rc2/doc/loop-in-case-sinking.md` -- the design this one's own "Level
  1" grew out of, and the "related, larger idea" section whose nested-
  loop dependency this design was specifically shaped to avoid.
- `rc2/doc/const-closure-fold.md` -- `RCConstClosure`, the existing
  "is this closure a compile-time constant" detection step 1 reuses
  for the zero-capture case (`SpecClosure.idr`'s own `lookupKnown`
  handles the non-zero-capture case itself, via `Bound`/`RUnderApp`
  tracing -- `RCConstClosure` alone doesn't cover it, see that
  function's own doc comment).
- `rc2/src/Compiler/RC2/Inline.idr` -- Criterion A / existing splicing
  machinery; investigated as a candidate for step 2's own "re-fold"
  half, ultimately not reused (it's `Lifted`-level, pre-RCExp, and
  already ran once by the time this pass runs -- see "Implementation
  notes" above) -- still directly relevant to the "why no nested-loop
  dependency" argument below.
- `idris2-src/src/TTImp/PartialEval.idr` -- upstream's own `%spec`
  mechanism, fully investigated here: `specArgs`/`getSpecArgs`'s own
  naming and closedness requirements, and `mkSpecDef`'s own error-only
  (not profitability-gated) fallback.
- `idris2-missing-containers`'s `test/src/Main.idr` -- `go`, this
  document's own motivating real-world case, and `rc2/BENCHMARKS.md`
  for the prior investigation explaining why this pass doesn't move
  the needle on that package's own `benchmarkHashMap` despite
  specializing `go` itself correctly.
