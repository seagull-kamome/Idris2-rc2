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

A bare `ROp`/`RCon`/`RAppName` (after peeling the same leading `RDup`/
`RDrop`/`RFree`/`RReleaseReuse` wrapper shapes
`Compiler.RC2.Loop.isInvariantExpr` already peels for an analogous
reason), with the same exclusions that function uses and for the same
reasons where they apply (kept in sync deliberately, not re-derived):

- `ROp`/`RAppName`'s own `lazy` field must be `Nothing` -- a deferred
  operation's evaluation *timing* is itself observable.
- `RCon`'s own `reuseFrom` must be `Nothing` -- entangled with a
  specific `RReuseOffer`'s own per-arm runtime uniqueness-check
  protocol, not this pass's to relocate.

**`RAppName` (an ordinary, named call) is eligible here even though
`Compiler.RC2.Loop`'s own hoisting deliberately excludes it.** That
exclusion is specific to *hoisting*: moving a computation to run
unconditionally, once per call, ahead of a loop that might otherwise
have skipped it entirely on a path that never iterates (see
`rc2/doc/loop-conversion.md`'s own "Loop-invariant expression hoisting"
section). Sinking only ever *reduces* how many times `value` runs --
down to "only when the one arm that needs it is actually reached" --
so a call that would have executed regardless is still guaranteed to,
now simply closer to (and only when reaching) its one actual use;
nothing here can turn a "never runs" path into a "now runs" one, the
same safety argument the whole pass already rests on. `RApp`/
`RUnderApp` (closure application/building) stay explicitly out of
scope -- more machinery (allocation, the trampoline) than a direct
named call, not analysed here. `RExtPrim` (genuine `%World`-threaded
effects) is never eligible, sunk or not.

Sinking a call needed one new piece of infrastructure this whole pass
didn't previously need: `Sink.idr` now threads a `SortedMap Int Rep`
(`reps`) through `applySinkExp`/`trySinkInto`/`trySinkIntoArms` --
seeded empty (every top-level argument is genuinely `RBoxed`, matching
`localRepIn`'s own "missing id defaults to `RBoxed`" convention,
mirrored directly from `Compiler.RC2.DualABI`'s own function of the
same name), extended at every `RLet` (its own declared `Rep`) and
`RLoop` (its own `loopParams`) -- the same shape
`Compiler.RC2.Loop.fillLoopContinuePostDrop`/`Compiler.RC2.DualABI
.applyCallSiteRewriteBody` already thread. It exists purely for
`consumedOperands`' own benefit: unlike `ROp`, whose `postDrop` already
lists exactly which of its own operands are Boxed, `RAppName` has no
such field -- *all* of its own arguments are unconditionally consumed
(ownership transferred to the callee) the moment the call runs, so
`consumedOperands` must filter that full argument list down to the
ones `reps` confirms are actually `RBoxed` before handing them to
`addOperandDrops` -- an already-native argument must never appear in
an `RDrop`'s own `vars` list. `tests/Test22BranchSinking.idr`'s own
`callSinkable` is the dedicated test: `buildMsg tag n`'s call sinks
into the one arm that reads its result, and the other arm gets an
explicit `drop [tag, n]` in its place.

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

### Sinking past an unrelated `let`

`trySinkInto` also sees through a leading `RLet` for some *unrelated*
local `y` sitting between `var`'s own binding and the eventual branch --
`let x = .. in let y = (doesn't read x) in <branch>` -- leaving `y`
exactly where it is and continuing the search for `x`'s own one
using arm past it. This case only ever fires for a `y` that couldn't
itself be sunk (if it could, `applySinkExp`'s own innermost-first walk
already rewrote that `let y = .. in <branch>` into the branch itself,
with `y`'s own binding moved inside one arm -- see "Algorithm" above --
so this `RLet` shape only survives when `y` is read on more than one
arm, or isn't itself `sinkEligible`). Bails (`Nothing`) if `y`'s own
value reads `var` -- that read happens unconditionally regardless of
which arm eventually runs, so `var` is genuinely needed before any
arm, the exact same reasoning `isDecidingOperand` already applies to a
branch's own scrutinee.
`tests/Test22BranchSinking.idr`'s own `skipUnrelatedLet` is the
dedicated test: `x`'s own binding reaches through `y`'s (`y` reads
both arms, `x` doesn't appear in `y`'s own computation) and lands
inside the one arm that reads `x`.

### Not peeling through `var`'s own death

**The single most important bug this whole pass produced, caught by
`refc-suite/buffer`'s own `TestBuffer.idr` -- a real miscompile, not
just a leak.** Every wrapper case in `trySinkInto` (`RDup`/`RDrop`/
`RFree`/`RReleaseReuse`/`RReuseOffer`) now checks whether *its own
target is `var` itself* before peeling through it, bailing to `Nothing`
if so.

`TestBuffer.idr` calls a chain of `IO ()`-returning `Data.Buffer`
functions in `do`-notation (`setByte buf 0 1; setBits8 buf 1 2;
setBits16 buf 2 3; ...`), each one's own `()` result immediately
discarded -- lowering to `let v5 = call prim__setByte [...] in drop
[v5]; let v6 = call prim__setBits8 [...] in drop [v6]; let v7 = ...;
let v8 = ...` before ever reaching an unrelated branch further down.
Each `RDrop [vN]` here is `vN`'s own, singular death, not some
unrelated ownership bookkeeping to see past on the way to a branch.
The *first* version of the wrapper-peeling clauses (`trySinkInto reps
var rep value (RDrop fc vs cont) = map (RDrop fc vs) (trySinkInto reps
var rep value cont)`, with no check on `vs`) didn't distinguish "an
unrelated drop sitting in the way" from "`var`'s own drop" -- it kept
searching straight through `v5`'s own death, through `v6`/`v7`/`v8`'s
identical chain, all the way to a distant, unrelated branch, and sank
`v5` there. The generated C referenced `var_5`/`var_6`/... in a scope
where they were never declared -- an undeclared-identifier compile
error, not a silent leak, since `v5` genuinely never reaches that far
in the real control flow at all.
`tests/Test23SinkPastSelfDrop.idr` reproduces the same shape directly
(a chain of `IO ()` calls whose result is discarded, followed by a
branch reading an unrelated value) as a dedicated regression,
independent of `Data.Buffer`.

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
  both arms), `deepSinkable` for sinking through two nested single-use
  branches in one pass (see "Sinking arbitrarily deep, not just one
  level" above), `callSinkable` for sinking a plain `RAppName` call
  (see "Deciding whether `value` is even a candidate" above), and
  `skipUnrelatedLet` for sinking past an unrelated `let` (see "Sinking
  past an unrelated `let`" above).
- `tests/Test23SinkPastSelfDrop.idr` -- dedicated regression for the
  most serious bug this pass produced, a real miscompile rather than a
  leak (see "Not peeling through `var`'s own death" above):
  reproduces `refc-suite/buffer`'s own `TestBuffer.idr` shape (a chain
  of `IO ()` calls whose result is immediately discarded, followed by
  a branch reading an unrelated value) directly, independent of
  `Data.Buffer`.
- `tests/Test2Recursion.idr`/`tests/Test9SelfTailLoop.idr`/
  `refc-suite/buffer/TestBuffer.idr` -- existing tests (the first two
  via Prelude functions they transitively pull in) that caught three
  of the four real bugs documented above; no dedicated new regression
  test needed for the first two since the existing full-suite run
  already exercises both shapes (the third, `TestBuffer.idr`'s own
  shape, got `Test23SinkPastSelfDrop.idr` as a dedicated regression
  instead, since relying on `refc-suite` alone to keep catching it
  felt too indirect for the single most serious bug found here).
