# Lambda lifting

rc2 lifts lambdas itself instead of taking upstream's `lambdaLifted`
from `getCompileDataWith`, in the same walk that turns the case trees
into `RCExp` (`Compiler.RC2.RC`'s Phase 1, `normalizeProgram`). Owning
the step is what keeps what lifting throws away (below), and lets every
pass before it (inlining, dead arguments, arity raising) work on the
case trees.

## Where the input comes from

rc2 asks `getCompileDataWith` (and `getIncCompileData`) for phase
`Cases`, which stops before upstream's own lifting. What comes back is
the same code upstream lifts, after its CExp-level work (merging
lambdas, fixing arities, CSE):

- `namedDefs`: every definition as `NamedDef`, in the order upstream
  lifts them (intrinsic constructors first). It is the `CDef` upstream
  lifts, with de Bruijn indices turned into names; `uniqueName` keeps
  every binder distinct from those in scope, so a name resolves to one
  binder.
- `mainExpr`: the closed main expression, turned into a `NamedCExp`
  with `forget`. Incremental compilation has none.

## What it produces

What upstream's `lambdaLifted` with `doLazyAnnots = False` would give,
already normalized:

- `__mainExpression`, then the lambdas lifted out of it, then each
  definition followed by its own lifted lambdas, newest first.
- Nested lambdas are merged into one lifted function taking all their
  arguments.
- A lifted function takes the enclosing variables its body uses, in
  scope order (innermost first), then its own parameters; the lambda
  becomes `RUnderApp` of it applied to those. The captures are found in
  the same walk: in a lambda's body, a name bound outside it gets a
  fresh id where it is first read, and is resolved in the enclosing
  body once the lambda's body is done (which may capture it there in
  turn).
- `Delay x` becomes a lambda of one ignored argument, `Force x` an
  application of `x` to an erased value.
- Lifted names count up per definition, in the order the lambdas
  finish (inner before outer).

Until 2026-09-30 this took two walks: rc2's own lifter produced
upstream's `Lifted`, which Phase 1 then normalized. The output of one
walk is the same program: on idris2-lsp every `rcexpr-lint` figure is
unchanged, and the 776 definitions `rcexpr-diff` reports differ only
in variable order (a `drop` list sorted by id), since ids are now
handed out as the walk meets them. The walk takes 0.55s instead of
0.67s for the two, but Late inline got slower (see below), so the
whole compile is not faster: the point is that `Lifted`, which kept
what lifting knows from reaching `RCExp`, is gone.

### Late inline is sensitive to id order

A lifted definition's captured parameters now get their ids where the
body first reads them, so they are larger than some of the body's own,
and a parent's ids interleave with its lambdas'. On idris2-lsp that
alone makes Late inline's first round 2.2s instead of 1.5s (4.7s
instead of 4.1s in all), for the same splices. Renumbering every
definition afterwards (parameters in order, then binders as they
appear) brought it back to 4.0s, but the renumbering itself took
0.38s, so it isn't done. Why the order matters is not known yet
(TODO.md).

## What lifting loses

These are gone once a lambda is lifted, and several rc2 passes exist
to rediscover them:

- **Where a lambda was.** Its body moves to a separate definition;
  the call site keeps a name and an argument count.
  `ArityRaise`'s apply fold, `ConstFold`'s fold of a closure applied
  where it is built, `SpecClosure`, `ArityRaise` and `ClosureCtx` all
  look for this again.
- **Laziness.** `Delay`/`Force` and their `LazyReason` become an
  ordinary lambda and application, so a `Lazy` value can't be memoized
  (TODO.md, "Semantics: `Lazy`/`Force`").
- **Which definition a lambda came from, and what it captured.**
- **`CLet`'s `InlineOk` flag.**

## What is kept: `LiftInfo`

`normalizeProgram` also returns a `LiftInfo` for every lifted
definition: the top-level definition it came from, whether it was a
lambda or a `Delay` (with the `LazyReason`, `Lazy` or `Inf`), and how
many parameters of its own it takes after the captured ones. A `Delay`
whose body is a lambda is merged with it, so it can take more than one.
`--directive dumplifts` writes the table to `<output>.lifts`
(`tests/Test122LiftOrigin` checks it).

No pass reads it yet. What it cannot serve as it stands:

- **`Force` sites.** A `Force` is an ordinary application to an erased
  value once lifted, and the table only describes definitions.
  Memoizing `Lazy` needs a mark at each `Force` or a thunk that updates
  itself, designed from the `Delay` side alone.
- **Definitions after later passes.** The table describes them as they
  were lifted, after inlining. SpecClosure clones, Early and Late
  inline splice, DeadCode prunes; a clone has no entry. A consumer
  must run early or treat a missing name as unknown; one that runs
  late wants the information carried on `RCDef` instead.
- **Incremental compilation.** The table there covers only the module
  being compiled, and `dumplifts` is not written.
- **The enclosing lambda.** A lambda is named after its body is lifted,
  so an inner lambda gets its name before the outer one exists; the
  table records only the top-level definition.
- **`InlineOk`.** It belongs to one `let`; the one walk could carry it
  onto `RLet`, but nothing would read it yet.

## Verification

The change of lifter was checked by comparing, byte for byte, the IR
dump (`--directive dumprcexpr`) of idris2-lsp and the IR and C of every
smoke test (`rc2/tests/snapshot.sh`) against the build with upstream's
lifting.
