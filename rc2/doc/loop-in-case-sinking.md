# Sinking a self-tail-recursive loop into its own loop-invariant dispatch case: investigated, designed, not implemented

This document records a design considered as a follow-up to
`rc2/doc/case-hoisting-scope.md` (which investigated and dropped the
mirror-image transform -- hoisting a loop-invariant `case` *out of* a
loop). It exists so a future session can pick this idea back up (or
decide against it) without re-deriving the analysis below. **Status:
designed on paper, not implemented.** No code changes accompany this
document.

## Motivation

`case-hoisting-scope.md` measured the cost of the shape it found in
`idris2-missing-containers`' `Data.Hash.Algorithm.Internal.feedCharOfString.go`
as "one dup, once per iteration" and judged that too small to justify
either implementation option it considered. That measurement undersold
the actual cost: **the real per-iteration cost is one dup per
destructured field that survives to be used inside the loop body, not
one dup total.** Confirmed directly in this project's own `--directive
dumprcexpr` dump of `idris2-missing-containers`' `MurMur3`
`HashAlgorithm` implementation (`rc2/BENCHMARKS.md`'s own
idris2-missing-containers section, this session):

```
case v1 of
  Data.Hash.Algorithm.MurMur3.MkMurMur3 [record] tag=Just 0 args=[v2, v3, v4] ->
    dup v2 x2
    dup v3 x2
    dup v4 x2
    drop [v1]
    ...
```

Three fields, each batched `x2` (two downstream uses each) -- six
effective increments every single iteration, for a `case` whose
scrutinee (`v1`, the `HashAlgorithm` state) never actually changes
across iterations of the *enclosing* per-character loop in the real
caller. `Compiler.RC2.Loop`'s existing loop-invariant-parameter
elision already keeps `v1` itself out of the loop's own carried
params -- but the `case` re-matching it, and the `dup`s reading its
fields back out, still re-run every iteration regardless.

## Relationship to `case-hoisting-scope.md`

That document's own option 2 ("hoist the whole `RConCase` out and wrap
the loop *inside* the surviving alt's body") is exactly this same
transform, described from the opposite direction (there: "pull the
case out of the loop"; here: "push the loop into the case"). It was
shelved there because, under the "one dup total" cost estimate, the
payoff didn't justify a dedicated pass. This document revisits it under
the corrected "one dup per surviving field" estimate, and also
completes the design that document only sketched.

## The transform

Given a function whose own body -- after peeling any leading
`RDup`/`RDrop`/`RLet` prologue -- is itself an `RConCase`/`RConstCase`
whose scrutinee is a loop-invariant local (a top-level argument, never
reassigned by anything `mapTailAppNames` would find as a tail
self-call target), and where each alternative independently contains
zero or more tail-recursive self-calls:

```
-- before
def go(v0, ...params...):
  case v0 of
    Alt1 [tag=0] args=[f1, f2, f3] -> <body1, may tail-call go(v0, ...)>
    Alt2 [tag=1] args=[g1]         -> <body2, may tail-call go(v0, ...)>

-- after
def go(v0, ...params...):
  case v0 of
    Alt1 [tag=0] args=[f1, f2, f3] ->
      loop:  -- RLoop, params now include f1/f2/f3 as loop-invariant captures
        <body1, tail self-calls become RLoopContinue>
    Alt2 [tag=1] args=[g1] ->
      loop:  -- an *independent* RLoop, siblings never nest
        <body2, tail self-calls become RLoopContinue>
```

Each alt that actually contains a tail self-call gets its own `RLoop`,
built by the *same* machinery `Compiler.RC2.Loop.applyLoop` already
has (shadow promotion, invariant hoisting, `RLoopContinue`
construction, `fillLoopContinuePostDrop`) -- just invoked once per alt
instead of once for the whole function, with that alt's own
destructured fields (`f1`/`f2`/`f3`) unioned into the same treatment
`applyLoop` already gives ordinary top-level arguments (eligible for
native-shadow promotion, invariant-parameter elision, etc.). Since the
`case` itself now runs exactly once (its scrutinee is loop-invariant,
so it always takes the same alt on every hypothetical re-entry -- and
there is no re-entry, since it's no longer inside the loop at all),
the fields' own `dup`s -- previously re-executed every iteration --
now execute exactly once, before the loop starts.

## Why this does *not* need genuine nested-loop support

This was the key correction found while designing this: the naive
framing ("multiple loops in one function") sounds like it needs
everything `TODO.md`'s "Future: nested self-tail-recursive loops" entry
warns about. It doesn't, for this specific shape.

**The loops this transform produces are siblings, never nested.** Each
alt gets at most one `RLoop`, and no alt's own body contains another
alt's loop -- they live in disjoint branches of the same `case`, exactly
one of which ever executes at runtime. At any point in the generated
tree, there is still at most one *enclosing* loop active. This means:

- `Compiler.RC2.DualABI`'s `loopContinueNativeReads` (currently a
  single `Maybe (List (Int, Rep))` slot for "the enclosing loop's own
  `loopParams`") does **not** need to become a stack. A stack is only
  needed when an `RLoopContinue` found while walking one loop's body
  could be ambiguous between an outer and an inner enclosing loop --
  which requires genuine nesting (one loop's body containing another
  loop), not siblings.
- `Loop.idr`'s own per-body helpers (`stripOwnership`, `renameRCExp`,
  `hoistInvariantPrefix`, `wrapInvariantShadows`, `markInvariantNative`,
  `dupInvariantBoxed`, `invariantLoopParamIds`,
  `elideInvariantContinueArgs`, `fillLoopContinuePostDrop`) do **not**
  need to learn to "stop at a nested loop's own boundary" -- there is no
  nested boundary to stop at. Each can be invoked independently, once
  per alt, on that alt's own disjoint sub-tree, exactly as it already
  runs once today on a whole function's body. No cross-contamination
  risk between alts, since they never share IR nodes.

So the actual prerequisite is narrower than `TODO.md`'s existing entry:
**"a function may produce more than one sibling `RLoop`, one per
independently-tail-recursive case alt"** -- not "loops may nest." See
"A related, larger idea" below for the shape that *does* need real
nesting.

## What would actually need to change

1. **A new detection step in (or ahead of) `applyLoop`**: recognize the
   "function body is (modulo prologue) a `RConCase`/`RConstCase` on a
   loop-invariant scrutinee" shape before falling back to today's
   whole-function single-loop scan. Needs a loop-invariance check for
   the scrutinee itself -- reusing the same shape of reasoning
   `invariantLoopParamIds` already applies to ordinary parameters, just
   applied to "is this local ever reassigned across any alt's own tail
   self-call," which for a fresh case-of-a-function-argument is a
   simpler question than the general one (the scrutinee here is always
   a plain top-level argument in the narrow shape this document scopes
   to, never a computed expression -- matching `case-hoisting-scope.md`'s
   own deliberately narrow scope, not attempting the general "arbitrary
   loop-invariant expression" version).
2. **A driver restructuring**: `applyLoop`'s own top-level entry point
   needs to become "try the case-sink shape first; if it matches,
   recurse the existing per-body core logic across each alt
   independently (0, 1, or N resulting sibling loops); otherwise fall
   back to today's existing whole-function behavior" instead of always
   doing the latter unconditionally.
3. **Folding an alt's own destructured fields into the existing
   argument-list treatment**: `applyLoop`'s core logic is already
   parameterized over `argIds` (today: the function's own top-level
   arguments). An alt's own `RConAlt.args` would need to feed into that
   same list when processing that alt's own body as its own
   mini-loop-host.
4. **Emit-side**: confirm `emitAltChain`'s existing single-alt/no-default
   "no `if` at all" collapse (`case-hoisting-scope.md`'s own finding)
   still applies once one or more alts' own bodies are themselves
   `RLoop` nodes rather than plain expressions -- expected to, since
   that collapse is about the branch dispatch itself, orthogonal to
   what an alt's own body contains, but worth confirming against
   generated C once implemented, not just assumed.

## Open questions / risks, not yet resolved

- **Interaction with `Compiler.RC2.MutualLoop`**: that pass also
  operates on tail-recursive shapes (merging mutually-recursive
  functions into one). Pipeline ordering (`RC2.idr`'s `toRCDefs`:
  `MutualLoop` runs before `Loop`) suggests no direct conflict, but this
  needs confirming once the case-sink detection is real -- in
  particular, whether a function `MutualLoop` has already merged could
  ever present the case-sink shape in a way this transform should (or
  should not) also apply to.
- **Layering `Compiler.RC2.ConAltNative` on top**: `case-hoisting-scope.md`'s
  own "related gap" section already flagged this as a natural
  follow-on (a native shadow surviving across the loop's own
  iterations, instead of being re-cached every time) -- still true
  here, still not designed in detail.
- **Getting the scrutinee-invariance check right** is the one place a
  correctness bug could hide: wrongly treating a scrutinee as
  loop-invariant when some alt's own tail-recursive continuation
  actually *does* change it (directly or through a chain of loop
  parameters) would silently freeze the case's own dispatch to the
  wrong alt after the first iteration -- a real behavioral bug, not
  just a missed optimization. Should reuse `invariantLoopParamIds`'s
  own existing, already-tested reasoning rather than write a new check
  from scratch.

## A related, larger idea, deliberately kept separate: inlining loop-only functions into an enclosing loop

Prompted by the same conversation this design came out of: once a
function can produce more than one `RLoop`, does that also open the
door to `Compiler.RC2.Inline` splicing a small function whose *entire*
body is itself a self-tail-recursive loop into a caller that is itself
looping? Today it cannot: `Inline`'s Criterion A (`rc2/doc/inlining.md`)
requires a call-free callee, and a self-tail-recursive function always
contains at least one call (to itself) at the point `Inline` runs
(before `Compiler.RC2.Loop` has turned that self-call into an
`RLoopContinue`) -- so such a function is never Inline-eligible today,
regardless of size, the same disjointness `rc2/doc/caf-memoization.md`'s
own "Interaction with Compiler.RC2.Inline" section already found for
CAFs.

This is a genuinely different shape from the sinking transform above:
splicing a callee's own loop into a call site sitting *inside* the
caller's own loop body produces one `RLoop` truly **nested** inside
another -- not siblings. That *is* exactly the shape `TODO.md`'s
"Future: nested self-tail-recursive loops" entry already warns needs
`Compiler.RC2.DualABI`'s `loopContinueNativeReads` to become a real
stack (keyed to the innermost enclosing loop), plus every one of
`Loop.idr`'s own per-body helpers listed above to be audited for
correctly stopping at (not reaching through) a nested inner loop's own
boundary -- the *expensive* half of `TODO.md`'s existing entry, which
the sinking transform above was specifically designed to avoid needing.

**Update**: a narrower, sibling mechanism that resolves the closure
*call itself* (`apply` -> direct `call`) without necessarily inlining
the target's own body -- and so needs none of the nested-loop machinery
this section describes -- is designed separately in
`rc2/doc/speculative-closure-specialization.md`. That document also
covers the *general* version of this same `go`-calls-a-closure shape
(not limited to a loop-only target), with its own profitability gate.

**Deliberately not pursued as part of this document's own design**:
building the full nested-loop foundation just to unlock this second
idea would mean paying the larger cost for a benefit that has not been
measured at all yet -- unlike the sinking transform above (grounded in
a real, profiled `dup`-per-field cost), no concrete program has been
found where a small loop-only function is actually called from inside
another loop's own body. If this is revisited, the right first step is
the same discipline this whole investigation followed: find or
construct a concrete case via `--directive dumprcexpr` on a real
program, and confirm the shape (and its cost) actually occurs, before
scoping an implementation.

## Files

- `rc2/doc/case-hoisting-scope.md` -- the mirror-image transform this
  document's own "Relationship" section builds on; its own "related
  gap" section on `ConAltNative` remains open here too.
- `rc2/src/Compiler/RC2/Loop.idr` -- `applyLoop` (starting at its own
  `mapTailAppNames` call), the machinery this design proposes invoking
  once per case-alt instead of once per function.
- `rc2/src/Compiler/RC2/DualABI.idr` -- `loopContinueNativeReads`, the
  field confirmed *not* needing a stack for this document's own narrow
  (sibling-only) scope, but which would for the "related, larger idea"
  section's own loop-inlining shape.
- `rc2/src/Compiler/RC2/Inline.idr` -- Criterion A (`isCallFree`), the
  reason a loop-only function is never spliced today; relevant only to
  this document's own "related, larger idea" section.
- `rc2/BENCHMARKS.md` -- idris2-missing-containers' `MurMur3` example,
  this document's own motivating `dup v2 x2` / `dup v3 x2` / `dup v4 x2`
  measurement.
