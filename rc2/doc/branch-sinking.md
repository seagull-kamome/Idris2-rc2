# Branch-local sinking (`Compiler.RC2.Sink`)

## What this pass does, and why it's separate from loop conversion

`let var = value in <branch>` (an `RConCase`/`RConstCase`/`RCmpCase`
immediately following the `let`) where `var` is read on only *one* of
the branch's own arms gets rewritten so `value`'s own computation moves
into that one arm instead -- every other arm no longer knows `var`
exists at all, and its own now-stale `drop [var, ...]` (if it had one)
is removed.

Found while reading `tests/Test21BoxedInvariantNotHoisted.idr`'s own
dump (the deliberately-not-hoisted negative case from
`rc2/doc/loop-conversion.md`'s "Loop-invariant expression hoisting"
section): `let v5 = MkCtx tag extra in (loop's own exit check) then v5
else (doesn't use v5) ...` rebuilds `v5` -- and immediately drops it,
unused -- on every single iteration that keeps looping, even though
it's only ever read on the loop's own exit arm.

**Deliberately not folded into `Compiler.RC2.Loop`.** Unlike hoisting,
this rewrite doesn't care whether `value` is loop-invariant at all --
`v5`'s own fields could be varying loop-carried values and the same
move would still be correct, since it only ever *reduces* how many
times `value` gets computed (down to "only on the one arm that
actually needs it, exactly when it's reached"). The motivating pattern
(`let X = ... in case/cmp ...`, one arm reads `X`, the other doesn't)
is entirely loop-independent; `tests/Test22BranchSinking.idr` exercises
it in an ordinary non-recursive function, with no loop anywhere in
sight.

**Sinking versus hoisting -- opposite directions, complementary
scopes.** `Compiler.RC2.Loop`'s own loop-invariant expression hoisting
(see `rc2/doc/loop-conversion.md`) moves a computation *out* of a loop
so it runs once per call instead of once per iteration; this pass moves
one *into* the one arm that needs it so it runs only when that arm is
actually reached, fewer times still. The two don't compete for the
same candidates in practice: hoisting only ever looks at a loop body's
own unconditional prefix (before any branch); sinking only ever fires
on a `let` immediately followed by a branch. A `let` sitting *between*
two branches, used by only one of the second branch's own arms, is
sunk first (this pass runs after `Compiler.RC2.Loop`, see "Pipeline
position" below) -- whether the value being sunk happened to be
loop-invariant or not never enters into it.

## Algorithm

`Compiler.RC2.Sink.applySinkExp` walks the whole tree, innermost-first:
an `RLet`'s own `body` is fully sunk *before* trying to sink the `RLet`
itself, so a chain `let a = .. in let b = f a in <branch>` resolves in
one pass -- `b` sinks into its one using arm first, then `a` (now only
reachable through that same arm's own already-sunk `let b = ...`) sinks
into the very same place right behind it. No fixed-point iteration
needed, mirroring `Compiler.RC2.Loop`'s own `hoistInvariantPrefix`
reasoning one level up (see that function's own doc comment) -- just in
the opposite direction (into a branch, not out of a loop).

### Sinking arbitrarily deep, not just one level

A successful sink re-feeds its own result through `applySinkExp` again
rather than returning it as-is. This matters whenever the one arm
`var` sinks into itself starts with another branch `var` is only read
on one side of: after the first sink, `var`'s own `RLet` now sits at
the top of that arm, wrapping a branch node -- exactly the shape
`applySinkExp`'s own `RLet` case looks for, so re-walking it lets
`trySinkInto` fire a second time, landing `var` one level deeper still.
This chains for arbitrarily many nested single-use branches, in the
same single pass, with no separate fixed-point driver: each success
strictly relocates `var`'s own binding into a strictly smaller
subtree of a finite tree, so the recursion always terminates.
`tests/Test22BranchSinking.idr`'s own `deepSinkable` is the dedicated
test for this -- `ctx` is read only when *two* nested flags are both
`True`, and sinks through both branches in one `Compiler.RC2.Sink` run.

### Deciding whether `value` is even a candidate (`sinkEligible`)

Only a bare `ROp`/`RCon` (after peeling the same leading `RDup`/
`RDrop`/`RFree`/`RReleaseReuse` wrapper shapes
`Compiler.RC2.Loop.isInvariantExpr` already peels for an analogous
reason), with the same two exclusions that function uses and for the
same reasons (kept in sync deliberately, not re-derived):

- `ROp`'s own `lazy` field must be `Nothing` -- a deferred operation's
  evaluation *timing* is itself observable.
- `RCon`'s own `reuseFrom` must be `Nothing` -- entangled with a
  specific `RReuseOffer`'s own per-arm runtime uniqueness-check
  protocol, not this pass's to relocate.

### Classifying each arm (`stripIfUnused`, `genuinelyUsedR`)

For each arm, `var` is classified as **Used** (genuinely read
somewhere in that arm's own body), **DropOnly** (the arm doesn't read
it, but has a stale `drop [var, ...]` for it -- `Compiler.RC2.RC`'s own
`annotate` already decided it's unused there, before this pass ever
ran), or **Absent** (doesn't mention it at all). `genuinelyUsedR` is
deliberately distinct from `RCExp.idr`'s own `freeLocalsR`: an
`RDrop`/`RFree`/`RReleaseReuse`'s own target contributes *nothing* to
it (`freeLocalsR` counts it as a use, which would make every sink
candidate look used everywhere -- exactly wrong for this purpose).

Sinking only fires when **exactly one arm is Used** and every other
arm is DropOnly or Absent. Two-or-more-Used and zero-Used are both left
alone (the first has nothing to gain; the second means `var` is truly
dead code, not this pass's problem to clean up).

**`var` must not be the branch's own deciding operand**
(`isDecidingOperand`) -- an `RCmpCase`'s own comparison args, or an
`RConCase`/`RConstCase`'s own scrutinee. A scrutinee must be evaluated
*before* any arm ever runs, so sinking `value` into one specific arm is
structurally impossible when `value` computes the very thing being
branched on. This was a real bug caught during development: `let v1 =
v0 - 1 in case v1 of 0 => ...; _ => (uses v1 to compute v0's own fib)`
(`tests/Test2Recursion.idr`'s own `fib`) looks, to a check that only
scans each arm's own body, exactly like "one arm uses it (`_`), the
other doesn't (`0` never reads `v1` again)" -- sinking `v1`'s own
binding into the `_` arm produced `case v1 of ...` referencing `v1`
before it was ever declared, an undeclared-identifier compile error.
`trySinkInto` checks `isDecidingOperand` before ever calling
`trySinkIntoArms`.

### The rewrite itself, and the second real bug it took to get right

Once sinking is confirmed safe shape-wise, `value` (with its own `var`/
`rep`) is re-`RLet`-bound at the top of the one Used arm; every DropOnly
arm has `var` stripped from its own `RDrop`'s `vars` list (the whole
node removed if that empties it -- `removeVarDrop` walks the *whole*
arm to find it, not just a leading-wrapper peel, since this pass runs
after both `Compiler.RC2.Reuse` and `Compiler.RC2.Loop`, unlike
`Compiler.RC2.ConAltNative`'s own `peelWrappers`, which can assume a
shallower position because it runs before either).

**`value`'s own consumed operands need the same treatment, in every arm
it *doesn't* sink into** (`consumedOperands`, `addOperandDrops`). This
was the second real, `valgrind`-confirmed bug found while building this
pass: `tests/Test9SelfTailLoop.idr` transitively pulls in
`Prelude.Types.getAt`, which has (before sinking) `let v4 = op -Integer
[v0, #1] postDrop=[v0] in case v1 of Cons ... => ...v4...; Nil => (v4
unused, so `drop [v4]`)`. `postDrop=[v0]` means `value`'s own
computation is what releases `v0` -- previously that release happened
unconditionally, once per iteration, as part of the loop's own
unconditional prefix. Sinking `v4`'s binding into the `Cons` arm without
also addressing this leaves `v0` released *only* on iterations that
actually take that arm -- on `Nil`, `v0` is never read (nothing there
mentions `v4`, and `v0` was only ever reachable *through* computing it)
and never released either: a genuine leak. `consumedOperands` collects
every Boxed operand `value` itself would have consumed reading it --
an `ROp`'s own `postDrop` list, or (tracking which ids a leading
`RDup` already protected with an extra reference) any `RCon` field
*not* `dup`'d first, whose own sole remaining reference moves straight
into the new constructor rather than surviving independently
(`tests/Test21BoxedInvariantNotHoisted.idr`'s own `dup v0; dup v1; con
_ [v0, v1]` `dup`s both fields first, so correctly contributes nothing
here). `addOperandDrops` prefixes every arm `value` doesn't sink into
with a `drop` for these -- exactly replacing the release `value`'s own
`postDrop`/field-move used to unconditionally provide every time --
bailing out to not-sink-at-all (`Nothing`) in the vanishingly unlikely
case one of them is already independently read there (would risk a
double-drop; costs nothing to guard against, should never actually
fire in practice).

## Pipeline position

Runs after `Compiler.RC2.Loop` (self-tail-call conversion), before
`Compiler.RC2.DualABI` (see `RC2.idr`'s own `toRCDefs`) -- late enough
that `RLoop`/`RLoopContinue` nodes are already in their final shape (so
this one pass reaches both inside a loop's own body and any ordinary,
non-looping function uniformly), but before `DualABI` ever needs to
reason about the tree's own shape. `genuinelyUsedR`/`removeVarDrop`
both have `RLoop`/`RLoopContinue` cases for exactly this reason --
every other tree-walk in this codebase predates `Compiler.RC2.Loop` in
the pipeline and so never needed one. `--directive nosink` disables
this stage alone, same convention as every other optional stage (see
`RC2.idr`'s own doc comment on `toRCDefs`).

## Files

- `rc2/src/Compiler/RC2/Sink.idr` -- the whole pass:
  `genuinelyUsedR`/`removeVarDrop`/`stripIfUnused` (arm classification
  and rewriting), `consumedOperands`/`addOperandDrops` (the second bug
  fix above), `sinkEligible`/`isDecidingOperand` (eligibility guards),
  `trySinkInto`/`trySinkIntoArms`/`applySinkExp`/`applySink` (the
  rewrite and whole-tree walk).
- `rc2/src/Compiler/RC2/RC2.idr` -- `toRCDefs`'s own pipeline wiring.
- `rc2/src/Compiler/RC2/ConAltNative.idr` -- `peelWrappers`, the
  "leading-wrapper-then-branch" idiom this pass's own wrapper-peeling
  cases mirror.
- `tests/Test21BoxedInvariantNotHoisted.idr` -- the motivating case,
  inside a self-tail loop (shared with `Compiler.RC2.Loop`'s own
  loop-invariant expression hoisting as its negative case).
- `tests/Test22BranchSinking.idr` -- the general, loop-independent
  case: one sinkable example, one that must *not* sink (`var` read on
  both arms), and `deepSinkable` for sinking through two nested
  single-use branches in one pass (see "Sinking arbitrarily deep,
  not just one level" above).
- `tests/Test2Recursion.idr`/`tests/Test9SelfTailLoop.idr` -- existing
  tests (via Prelude functions they transitively pull in) that caught
  the two real bugs documented above; no dedicated new regression test
  needed for either since the existing full-suite run already exercises
  both shapes.
