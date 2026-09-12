# Speculative, profitability-gated closure-argument specialization: investigated, designed, not implemented

This document records a design considered as "Level 1" of the closure-
specialization idea `rc2/doc/loop-in-case-sinking.md`'s own "A related,
larger idea" section first raised (resolving a higher-order function's
own closure-argument `apply` to a direct named `call`, without
necessarily inlining the target's body). It also records a full
investigation of whether upstream Idris2's own `%spec` mechanism could
provide this for free, and why it can't for the concrete case that
motivated it. **Status: designed on paper, not implemented.** No code
changes accompany this document.

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

## Open questions / risks, not yet resolved

- **Multiple specialized parameters on one function**: `go` only has
  one closure parameter; a function with several would need the
  candidate set in step 1 to be a set of *tuples* (one target per
  parameter), multiplying the number of distinct `(g, targets...)`
  clones attempted -- still bounded (by the product of each
  parameter's own distinct-target count, typically small), but not
  designed in detail here.
- **Where in the pipeline this runs**: needs to run after `ConstFold`
  (so `RCConstClosure`-folded targets are visible) but interacts with
  `Compiler.RC2.Inline`'s own existing pass -- does this become a new
  step between them, or a refinement of `Inline` itself given how much
  machinery (splicing, Criterion A re-application) it reuses? Not
  decided.
- **Re-annotating a clone's own ownership**: a cloned-and-rewritten `g`
  needs `Compiler.RC2.RC`'s `annotate` (and potentially `Reuse`/
  `ConAltNative`) to run again over just that clone, the same way
  `Compiler.RC2.Inline`'s own existing splicing already has to handle
  re-deriving ownership for spliced-in code -- not a new problem, but
  worth confirming the existing machinery covers a *clone of a whole
  top-level definition*, not just a spliced-in call-free callee body.
- **Interaction with `DupMerge`/`Loop`**: since this would run before
  those (matching `RC2.idr`'s own `toRCDefs` ordering, where `Inline`
  itself already runs early), no conflict is expected, but not verified
  against the actual pipeline order.
- **No profiled evidence yet that keeping this bounded (memoized per
  distinct target) actually avoids real-world blowup** -- the design
  above is reasoned from the user's own prior experience with
  unrestricted specialization, not from a new measurement. Worth a
  synthetic stress case (a function called from many distinct closure
  targets) before implementing, to confirm the memoization bound
  behaves as expected.

## Files

- `rc2/doc/loop-in-case-sinking.md` -- the design this one's own "Level
  1" grew out of, and the "related, larger idea" section whose nested-
  loop dependency this design was specifically shaped to avoid.
- `rc2/doc/const-closure-fold.md` -- `RCConstClosure`, the existing
  "is this closure a compile-time constant" detection step 1 reuses.
- `rc2/src/Compiler/RC2/Inline.idr` -- Criterion A / existing splicing
  machinery, reused (unchanged) by step 2's own re-fold and directly
  relevant to the "why no nested-loop dependency" argument above.
- `idris2-src/src/TTImp/PartialEval.idr` -- upstream's own `%spec`
  mechanism, fully investigated here: `specArgs`/`getSpecArgs`'s own
  naming and closedness requirements, and `mkSpecDef`'s own error-only
  (not profitability-gated) fallback.
- `idris2-missing-containers`'s `test/src/Main.idr` -- `go`, this
  document's own motivating real-world case.
