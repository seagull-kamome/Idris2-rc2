# Lambda lifting

rc2 lifts lambdas itself (`Compiler.RC2.LambdaLift`) instead of taking
upstream's `lambdaLifted` from `getCompileDataWith`. For now the output
is exactly upstream's; owning the step is groundwork for keeping what
lifting throws away (below).

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

Nothing converts the named code back to indices first: the lifter
resolves each `NmLocal` against the current scope (`isVar`) as it goes.

## What it produces

`lambdaLiftProgram` returns what upstream's `lambdaLifted` would with
`doLazyAnnots = False` (the value rc2 always passed):

- `__mainExpression`, then the lambdas lifted out of it, then each
  definition followed by its own lifted lambdas.
- Nested lambdas are merged into one lifted function taking all their
  arguments.
- A lifted function captures only the enclosing variables its body
  uses (the capture analysis is upstream's, copied since it is
  private), and the lambda becomes `LUnderApp` of it applied to those.
- `Delay x` becomes a lambda of one ignored argument, `Force x` an
  application of `x` to an erased value.
- Lifted names count up per definition, in the order the lambdas
  finish (inner before outer), as upstream's `genName` does.

Binder names can differ from upstream's (`uniqueName` renames shadowing
binders), which nothing downstream reads: `Compiler.RC2.RC` numbers
every variable afresh.

## What lifting loses

These are gone once code is `Lifted`, and several rc2 passes exist to
rediscover them. Keeping them is the next step:

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

## Verification

The change of lifter was checked by comparing, byte for byte, the IR
dump (`--directive dumprcexpr`) of idris2-lsp and the IR and C of every
smoke test (`rc2/tests/snapshot.sh`) against the build with upstream's
lifting.
