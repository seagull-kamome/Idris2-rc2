# `Compiler.RC2.Inline`: whole-program `Lifted`-to-`Lifted` inlining

## Motivation

`Compiler.RC2.RC`'s `tryFuseCompare` fuses a *direct* primitive comparison
immediately consumed by a two-way Bool match into a single native
`RCmpCase` -- no boxed `Bool` is ever materialised, and the branch reads
its operands natively. This only fires when the comparison is a bare
`LOp`/`ROp` sitting right next to the match, though: when the comparison
is reached through an interface method call instead (e.g. `acc <= 0` via
`Ord Int`'s `<=`, a genuine, statically-resolved top-level function, not
a dictionary-parameterised one -- only fixed-width scalar types are ever
native-eligible to begin with), fusion never fires on its own. The
comparison sits inside `<=`'s own separate definition, invisible to the
caller's own fusion analysis.

`Compiler.RC2.Inline` closes this by splicing a small, call-free
callee's own body directly into its call site, run once, before
`Compiler.RC2.RC`'s own Phase 1 (`normalize`) ever sees the program --
so from `RC.idr`'s point of view, the call was never there. See
`rc2/tests/Test15CompareFusionThroughCall.idr` for the exact motivating
shape and how to check it via `--directive dumprcexpr`/`--directive
noinline`.

## Pipeline position

```
Lifted (Compiler.LambdaLift)
  -> Compiler.RC2.Inline          (this module -- whole-program inlining, Lifted -> Lifted)
  -> Compiler.RC2.RC.normalize    (Phase 1: ANF-style, native type inference)
  -> Compiler.RC2.RC.annotate     (Phase 2: ownership -- RDup/RDrop/RFree)
  -> Compiler.RC2.Reuse           (constructor-reuse-in-place)
  -> Compiler.RC2.ConAltNative    (native-shadow field caching)
  -> Compiler.RC2.MutualLoop      (mutual tail recursion -> one merged function)
  -> Compiler.RC2.Loop            (self-tail-call -> RLoop/RLoopContinue,
                                    plus native-shadow promotion)
  -> Compiler.RC2.DualABI         (worker/wrapper synthesis, call-site rewrite)
  -> Compiler.RC2.Emit            (purely mechanical RCExp -> C)
```

Run first, before anything RC2-specific exists at all -- `Compiler.RC2.RC2`'s
own `toRCDefs` calls `applyInlineLifted` on the raw `lambdaLifted` list
before any other stage. `--directive noinline` skips it, for the same
kind of A/B regression isolation `noloop`/`noconaltnative`/etc. already
provide (see `RC2.idr`'s own module note on `toRCDefs`).

## Eligibility: Criterion A only

A callee is inlined at *every* one of its own call sites when:

- it's a genuine top-level definition (`MkLFun args scope body` with
  `scope = []` -- a lifted-out closure helper, which always has a
  non-empty `scope` of its own captured free variables, is never
  eligible: inlining requires a *closed* body, referencing only its own
  `args`);
- its own body is *call-free* (`isCallFree`: no `LAppName`/`LUnderApp`/
  `LApp`/`LExtPrim` anywhere in it); and
- its own body is small (`sizeOf body <= smallBodyThreshold`, currently
  24 -- a coarse structural node count, not calibrated against actual
  generated-C size).

This is deliberately narrower than a general "inline small functions"
pass. The call-free requirement means an eligible callee can never
itself contain a further call to inline -- so `inlineLifted`'s own
whole-program rewrite needs only one pass, never a fixpoint: splicing in
a call-free body can't expose a *new* inlining opportunity inside what
was just spliced (only inside the call's own *arguments*, which are
processed bottom-up before the call itself is considered).

A second criterion (single call site, whole-program, ordered via a
Tarjan-SCC call graph reusing `Compiler.RC2.MutualLoop`'s own `Graph`/
`tarjanSCCs`) was investigated in an earlier session alongside Criterion
A, but confirmed *not* to reach the separately-documented monadic-bind
reuse gap (`rc2/doc/reuse-monadic-bind-gap.md`) and not otherwise
load-bearing for any currently-known gap. Not implemented here, to keep
this pass's own blast radius matched to the problem it actually solves;
`Graph`/`tarjanSCCs` were still made `public export`/`export` in
`MutualLoop.idr` in case a future session revisits this. It has since been
implemented for loop-free callees: see "Criterion B at `Lifted`" below.

## The `allLiteralArgs` guard

A call whose arguments are *all* bare `LPrimVal` literals is never
inlined, even if otherwise eligible. Found necessary via
`Test6NativeInts.idr`'s own `chainInt8 100 100`-shaped calls: once a
fixed-width arithmetic chain is spliced in with every operand a
compile-time constant, gcc's own `-Werror=overflow` can statically prove
an intentional two's-complement wraparound "overflows," turning a
correct, deliberate test into a compile error. Vacuously true for a
nullary call (no arguments to be "all literal" over), so the guard only
ever actually fires once there's at least one argument -- a nullary
call has no such folding risk in the first place.

## IR plumbing: `Weaken`/`Substitutable` for `Lifted`

Splicing a callee's body into a call site is a capture-avoiding
substitution: replace every occurrence of a callee argument with the
corresponding caller-side expression, correctly re-indexing every local
variable reference along the way. `Lifted`'s own `LLocal` uses the exact
same `IsVar`-based de Bruijn representation as `Core.TT.Term`'s own
`Local`, so this module ports `Core.TT.Term`'s own `insertNames`/
`GenWeaken`/`FreelyEmbeddable` instances and `Core.TT.Term.Subst`'s own
`substTerm`, verbatim in structure, onto `Lifted`/`LiftedConAlt`/
`LiftedConstAlt` -- no `Lifted`- or rc2-specific capture-avoidance
machinery needed at all; the generic `Core.TT.Var`/`Core.TT.Subst`
combinators (`insertNVarNames`, `find`) do all the actual index
arithmetic.

Two things `Term`'s own instances never needed, since `Term`'s own
`Bind` only ever introduces one name at a time:

- **`LiftedConAlt`'s multi-name binder.** A constructor alternative
  binds a whole *list* of names (`args`) at once
  (`Lifted (args ++ vars)`), not just one -- `insertNamesConAlt`/
  `substConAlt` need one extra `appendAssociative` reshuffle to line the
  types up, ported from upstream `Compiler.CaseOpts`'s own
  `shiftBinderConAlt`, which already solves the identical shape for
  `CConAlt`.
- **Erasure.** `Lifted`'s own `vars` scope index is never used at
  runtime by *any* constructor except inside an already-erased `IsVar`
  proof (`LLocal`'s own `(0 p : IsVar x idx vars)`) -- Idris2's own
  forced-argument detection erases it throughout automatically. Every
  helper this module adds that mentions a scope-list implicit by name
  (`insertNamesConAlt`, `substConAlt`, `toSubst`, `inlineCall`) has to
  mark it `0` explicitly to match, or the compiler rejects the call with
  "`<name>` is not accessible in this context" -- `Lifted`'s own erased
  index simply doesn't carry the runtime information a non-erased
  parameter would need. This is also *why* `FreelyEmbeddable Lifted`'s
  own `embed` (append-on-the-right, used to widen a closed callee body
  into the caller's own scope before substituting) can just be
  `believe_me`: with zero runtime information in the index either way,
  there is nothing an unsafe cast could get wrong.
- **`SizeOf` from a `Subst`'s own spine, not `mkSizeOf`.** `inlineCall`
  needs a `SizeOf calleeArgs` to seed the substitution, but `calleeArgs`
  is erased in its own context, so `mkSizeOf calleeArgs` (which
  genuinely counts a real list's length) can't be used. `env`'s own
  `Subst` value already encodes that length as real, non-erased
  cons-spine structure, so `sizeOfSubst` reads it from there instead.

## Case-of-case collapse

Substituting a call's own scrutinee-shaped argument into a `case`
position produces a "case of case" -- `case (case x of ...) of ...` --
that `tryFuseCompare` doesn't recognise on its own. `collapseCaseOfCase`
ports upstream `Compiler.CaseOpts`'s own `doCaseOfCase`/
`doCaseOfConstCase`/`tryCaseOfCase` (the `CExp`-level case-of-case half
only -- `Lifted` has no `LLam` at all, since lambda-lifting already
eliminated every lambda, so upstream's own "lift out lambda" half,
`caseLam`, has no counterpart here) onto `Lifted`, and applies it
bottom-up across the whole tree after inlining. To bound the risk of
duplicating a large outer case into every inner branch, collapsing only
fires when the inner case's own alternatives are all constructor-headed
(or there's exactly one, with no default) -- identical restriction to
upstream's own `canCaseOfCase`.

### Size budget

The shape restriction above bounds *what* gets collapsed, not *how
much* -- `doCaseOfCase`/`doCaseOfConstCase` duplicate the entire outer
`alts`/`def` once per inner branch, and nothing bounded the size of
`alts`/`def` itself. A chain of small, case-returning, call-free
functions (exactly Criterion A's own target shape -- e.g. a run of
`if pI x then ... else ...` guards, each `pI` a small enum-driven
predicate) spliced into successive scrutinee positions compounds this
*multiplicatively*: each level duplicates the already-collapsed result
of the level below into every one of its own branches.

This is architecturally different from upstream's own exposure to the
same `CaseOpts` code (see "Case-of-case collapse" above): upstream's
default automatic-inlining heuristic (`Compiler.Opts.InlineHeuristics`'s
`simple`) explicitly excludes any callee whose body is itself a
`CConCase`/`CConstCase`, so upstream's `caseOfCase` only ever collapses
nesting already present in the source, never nesting its own inliner
just created. This pass deliberately targets the opposite shape --
inlining a small case-returning callee into a scrutinee position is the
entire point (see Motivation above) -- so it can't adopt upstream's
"don't inline case-shaped bodies" guard without losing its own reason
to exist; upstream's approach genuinely doesn't transfer here.

Confirmed empirically with a synthetic N-level guard chain (`if pI x
then ... else ...`, `pI : Tri -> Bool` a 3-alt enum predicate,
`rc2/doc/inlining.md`'s own history -- generator script not checked in):
generated-C line counts roughly *doubled* per additional level --
1,185 / 19,041 / 37,473 / 74,337 lines at N=5/10/11/12 -- against 1,044
lines for the same N=10 source compiled with `--directive noinline`
(no growth with N at all, since nothing gets spliced into a scrutinee
position in the first place). Memory was exhausted outright around
N=15. Crucially, `--timing 2` showed `rc2: Inline` itself finishing in
~0ms even as it built the bloated tree (duplicating already-built nodes
is cheap allocation); the wall-clock cost only became visible in the
*next* stage to do real per-node work on the now-huge tree (`rc2: RC
normalize`, 0.378s at N=10) -- so a hang or slowdown attributed to "the
inline stage" by wall-clock/memory observation may show up downstream
of `Compiler.RC2.Inline`'s own `logTime` line, even though the size
blowup originates there.

**Fix**: `tryCaseOfCase`'s two clauses now also require
`duplicationCount * outerSize <= caseOfCaseSizeBudget`
(`caseOfCaseSizeBudget = 200`), where `outerSize` is `sizeOf`/
`sizeOfConAlt`/`sizeOfConstAlt` (the same coarse structural node count
Criterion A's own `smallBodyThreshold` uses, moved earlier in the file
so this guard can reuse it) applied to the outer `alts`/`def`, and
`duplicationCount` is how many places they'd be copied into (`length
xalts`, plus one more if `xdef` is present). Skipping a collapse is
always semantically safe -- the result is just the original, uncollapsed
`case (case ...) of ...`, correct but unfused past that point. Because
the check runs bottom-up on the *already-realised* size of `alts`/`def`
(which already reflects any duplication from collapses lower in the
tree), a chain that would otherwise keep compounding gets capped at the
first level where cumulative size crosses the budget; every level above
that sees an already-at-or-over-budget input and keeps skipping, rather
than the multiplication resuming.

Re-running the same synthetic generator after the fix: generated-C line
counts grew roughly *linearly* instead -- 729 / 822 / 862 / 922 / 1,022
lines at N=5/10/12/15/20 (~20 lines per additional level) -- and the
full regression suite (87/87, including `Test15CompareFusionThroughCall`
both functionally and under `valgrind`) stayed green, confirming the
budget doesn't interfere with the pass's own motivating case at the
sizes that actually occur there.

### Size bookkeeping: threaded, not re-scanned

The synthetic N-chain benchmark above no longer crashes, but it also
never exercised the guard's own *measurement* cost: computing
`outerSize` via a fresh top-down `sizeOf`/`sizeOfConAlt` scan of
`alts`/`def` at *every* candidate site. On a large real program this
scan cost dominated `rc2: Inline`'s own wall-clock time outright --
144s on one real large program, even though the collapse *duplication*
itself was already correctly bounded by the budget above. The telltale
sign: `rc2: RC normalize` immediately after showed no measurable
difference between `--directive noinline` and default (0.20s vs.
0.24s) on the same program, meaning the cost sat *inside* `rc2:
Inline` itself, not downstream of it (unlike the synthetic N-chain
case earlier, where the size blowup was real but Inline's own
`collapseCaseOfCase` finished fast and `rc2: RC normalize` absorbed
the visible wall-clock cost of processing the now-larger tree). A
large real program has many scattered case-of-case candidate sites
(not just one pathological chain), each re-walking its own,
unboundedly large enclosing `alts`/`def` from scratch -- effectively
O(number of candidate sites × average enclosing context size).

**Fix**: `collapseCaseOfCase`/`collapseConAlt`/`collapseConstAlt` now
return a `Sized` pair (`szOf`/`valOf`) instead of a bare tree, so each
node's own size is computed exactly once, incrementally, as a
byproduct of the same bottom-up fold that was already building it --
never re-derived by a separate scan. `caseOfCaseHere`'s retry loop
(up to 5 attempts at one tree position) threads a `CollapseState`
(`totalSize`, `branchesSize` -- i.e. `outerSize`, and the tree itself)
rather than a bare tree, so a *chain* of successive collapses at one
position also never re-scans: `doCaseOfCase`/`doCaseOfConstCase`
update both sizes via a closed-form formula instead of re-deriving them
from the result --

```
newBranchesSize = sizeOf(xalts) + sizeOf(xdef) + duplicationCount * (1 + outerSize)
```

(`weakenNs`, used to re-index a duplicated copy of `alts`/`def` into a
deeper scope, never changes node count, so a duplicated copy's size is
always exactly the input `outerSize`; each of the `duplicationCount`
copies also gains the one wrapper node `updateAlt`/`updateDef` builds
around it, hence the `+ 1` per copy). `xalts`/`xdef` (the *inner*, just-
spliced-in side) are still scanned fresh via the plain, unthreaded
`sizeOf`/`sizeOfConAlt`/`sizeOfConstAlt` -- when they come from this
pass's own inlining they're bounded by Criterion A's own
`smallBodyThreshold` regardless of program size, and when they instead
come from a genuinely large, naturally-occurring nested source `case`
(this pass's `collapseCaseOfCase` runs on *every* definition, inlined
or not), that scan was already exactly this expensive before any of
this bookkeeping existed -- no new cost introduced on that side.

Re-verified: same synthetic generator, same linear line-count growth as
above (threading the sizes is a pure performance change, not a
behavioural one), and the full regression suite stayed green (87/87,
`Test15CompareFusionThroughCall` included).

A separate, unrelated cost was found while chasing this: N=25 of the
same synthetic generator took 5.6s in upstream's own "Elaborating"
step (nothing to do with rc2 -- every `rc2:`-prefixed stage stayed at
0.000s) -- elaborating one literal 26-deep nested `if`-`then`-`else`
expression is apparently expensive for upstream's own elaborator,
regardless of `--directive noinline`. Not investigated further (real
source code essentially never writes a single-line N-deep `if` chain
by hand at this depth; the synthetic generator did so specifically to
isolate the case-of-case shape), but worth noting so it isn't confused
with this pass's own behaviour if it resurfaces.

## A literal argument's own Rep (`buildSplice`'s constant clause)

`buildSplice`'s `RCLoc` clause has always asked `nativeEligible`
whether the callee reads the parameter natively, and bound the fresh
`RLet` `RNative ty` when it does. Its *constant* clause -- the one
taking an argument `Compiler.RC2.ConstFold` already folded to an
`RCConst`/`RCEmptyCon`/`RCConstCon`/`RCConstClosure` -- skipped that
question entirely and always bound `RBoxed`.

For a native-eligible literal (`Types.litRep`) that meant a fresh box
which the very next statement unboxed again. The common consumer is an
`RLoop`'s own native `initial=` slot, left behind when a
loop-converted callee is spliced into its one caller:

```
let v402 : Boxed = #0
let v401 : Boxed = #100000
loop ["v400:Native Int64", "v399:Native Int64"] initial= [v401, v402] prologueDrop= [v401, v402]
```

```c
IDRIS2RC2_Value * var_401 = idris2rc2_mkInt64(INT64_C(100000));
int64_t var_400 = (var_401 == NULL) ? 0 : (idris2rc2_to_i64(var_401));
```

The clause now asks the same question the `RCLoc` one does. A literal
bound `RNative` reaches `Compiler.RC2.Emit`'s own `declareLet` case for
`(RNative _, RPrimVal _ c)`, which puts it straight into `InlineMap` --
no C variable declared at all, the literal rendered inline at its one
use. A non-literal constant has no native representation and stays
`RBoxed`, which `litRep` already answers `Nothing` for.

This needed two matching corrections in the shared native-read analysis
before it could fire at all -- an `RLoop`'s own `initial=` slot and a
constant-`case` scrutinee both had to start counting as native reads in
`Compiler.RC2.Loop`'s `nativeArgTypes`, and stop counting as
disqualifying uses in `hasNonNativeUse` (against the same shared
`nativeSlotTy`/`constAltsNativeType`, so the two can't disagree). See
`doc/dual-abi.md`'s "Extending the promotion to `case` scrutinees" for
both, and for the measurements.

## Bugs found and fixed

An earlier attempt at this pass, this session, was fully reverted after
the full regression suite surfaced a real, `valgrind`-confirmed leak in
`Test9SelfTailLoop`'s own `collatzLike` once inlining made comparison
fusion reach a self-tail-loop's own accumulator for the first time. Two
rounds of narrowing the case-of-case collapse (bounding it, then
disabling it outright) left the leak byte-for-byte unchanged, and the
attempt was shelved with the root cause undiagnosed (see `TODO.md`'s own
git history for that investigation).

The real root cause, found in the *next* session by reproducing the leak
with a hand-written source program containing zero function calls to
inline at all, turned out to be two completely independent, pre-existing
bugs in `Compiler.RC2.Loop`/`Emit` (a missing `RLoopContinue` `postDrop`
field, and an unfreed ephemeral box in `Emit.idr`'s own `ROp` case),
neither one in this pass -- see `rc2/doc/loop-conversion.md`'s "Bugs
found and fixed" #5 for the full write-up of both.

Both are fixed independently of this pass -- neither
fix touches `Inline.idr` at all. This pass's own logic (the IR plumbing,
the case-of-case collapse, both eligibility criteria) was already
correct at the point the original leak was found, confirmed via
`--directive dumprcexpr` on the motivating comparison-fusion case both
then and after this reimplementation.

A separate, narrower bug specific to *this* implementation attempt: the
`--directive noinline` wiring was silently broken partway through the
original debugging session (`toRCDefs` called `applyInlineLifted`
unconditionally, and `"noinline"` was missing from `compileExpr`'s own
recognised-directives list), which produced a wrong intermediate
conclusion ("the leak is pre-existing, unrelated to this pass") since
both compared builds secretly had inlining enabled. Re-verified this
time by diffing the generated C with and without `--directive noinline`
before trusting any A/B comparison built on it again (see
`rc2/tests/Test14SmallFunctionInline.idr`'s and
`Test15CompareFusionThroughCall.idr`'s own doc comments, which both
describe exactly what to expect changed between the two builds).

## Criterion B at `Lifted`: loop-free single-caller callees (2026-09-25)

The second criterion, dropped above as not load-bearing, became
load-bearing once ConstFold's known-constructor fold and
`Compiler.RC2.PushCon` existed (`constructor-escape-analysis.md`). A
callee that returns a constructor its only caller immediately matches
leaves the construction and the `case` in one function only once it
is inlined. `LateInline` does inline it, but after RC annotation, where
those folds can't reach. It runs that late only for callees that are
recursive until `Loop` converts them; a callee that never recursed
doesn't need to wait.

A callee is inlined here, at its one call site, when:

- it is a top-level `MkLFun` with at least one argument (a 0-argument
  definition is a CAF, evaluated once however often it is referenced);
- it has exactly one saturated `LAppName` occurrence, whole-program;
- it is in no call-graph cycle, a self-call included (`MutualLoop`'s
  `tarjanSCCs` over the `LAppName` graph);
- that call site isn't lazy (`LAppName`'s `lazy` is `Nothing`).

The caller may be a CAF. A first version excluded CAF callers, because
code spliced into `main`'s memoized body came out unoptimised. The
real cause was that DualABI and Sink never entered `RMemoize` at all
(`caf-memoization.md`, "Limitations"). That is fixed, and the
exclusion is gone.

Definitions are processed callees first (the reverse of `tarjanSCCs`'
order, as `LateInline` does), and an eligible callee enters the map in
its already-processed form, so a chain `A -> B -> C` collapses in one
pass. There is no size limit, as for `LateInline`: one call site means
no copy is added. `%noinline` isn't consulted, as it isn't by
Criterion A or `LateInline` either.

**Arguments are now bound, not substituted.** Splicing substituted
each argument expression for every occurrence of its parameter, so a
parameter used twice evaluated its argument twice, and an unused one
never evaluated it. `sq x = x * x` inlined at `sq (expensive y)`
computed `expensive y` twice. Criterion A has done this since it was
written. Criterion B's bodies are arbitrary, so it had to be fixed
before B could use the same splice. `spliceArgs` now binds every
non-atomic argument (anything but a local, a literal or an erased
value) with an `LLet` first, and substitutes only locals. The fix
covers both criteria.

Measured on idris2-lsp, together with ConstFold's known-partial fold
(`constructor-escape-analysis.md`), against the build before either:
`apply` 11,326 -> 10,039, `partial` 16,448 -> 15,788, allocating `con`
39,741 -> 38,257, IR lines -1.2%, compile 27.9s -> 29.3s. 3,158
callees qualify at `Lifted`, against the roughly 11,800 `LateInline`
splices. Most of those become single-caller only after ConstFold and
SpecClosure turn closure applications into direct calls (8,126 qualify
just before RC annotation), so `LateInline`'s own splicing now also
runs once there, as the "Early inline" stage
(`constructor-escape-analysis.md`, "Early inline").

## Criterion B, revisited: `Compiler.RC2.LateInline`

The "single call site, whole-program" criterion this doc's own
"Eligibility" section above describes as investigated-but-shelved was
picked back up in a later session, as its own separate pass --
`Compiler.RC2.LateInline`, operating on `RCExp` rather than `Lifted`,
and running much later in the pipeline than `Compiler.RC2.Inline`
above. Disable with `--directive nolateinline`.

### Motivation

`Compiler.RC2.SpecClosure` builds a specialized clone of a
closure-argument-taking function for each of its own call sites (see
`rc2/doc/speculative-closure-specialization.md`) -- a clone that, if
the original function was self-recursive, is *also* self-recursive at
the point SpecClosure produces it. That self-recursion is exactly what
made Criterion A's own call-free requirement (this doc's "Eligibility"
section) reject such a clone outright: a callee containing a call
(even to itself) isn't call-free.

`Compiler.RC2.Loop` (and `MutualLoop`) already collapse ordinary self-
(and mutual-tail-)recursion into `RLoop`/`RLoopContinue` -- a goto-based
loop with zero remaining function calls back to the original name. A
clone whose call graph looked recursive *before* Loop conversion looks
completely ordinary, non-recursive, and every bit as inlinable as any
other function *after* it. Since a SpecClosure clone is built for
exactly one call site by construction, it's also unconditionally
single-caller-eligible the moment Loop conversion is done with it --
finally giving Criterion B's own single-caller criterion a concrete,
load-bearing motivating case, where the earlier investigation found
none.

### Pipeline position

```
  -> Compiler.RC2.MutualLoop      (mutual tail recursion -> one merged function)
  -> Compiler.RC2.Loop            (self-tail-call -> RLoop/RLoopContinue,
                                    plus native-shadow promotion)
  -> Compiler.RC2.LateInline      (this pass -- whole-program inlining, RCExp -> RCExp)
  -> Compiler.RC2.Sink            (branch-local let-value sinking)
  -> Compiler.RC2.DualABI         (worker/wrapper synthesis, call-site rewrite)
  -> Compiler.RC2.DeadCode        (whole-program reachability pruning)
  -> Compiler.RC2.DupMerge
  -> Compiler.RC2.Emit            (purely mechanical RCExp -> C)
```

Strictly after Loop/MutualLoop conversion -- see "Motivation" above for
why running any earlier would make this pass reject exactly the
clones it exists to reach. Strictly before Sink, so a value this pass
just spliced in (e.g. a whole loop, now living as one branch's own
`RLet` value) is still eligible for Sink's own branch-local placement
decision. Strictly before DualABI -- see "Known limitation: DualABI's
own native-eligibility analysis" below for the real, found consequence
of that choice, and why it wasn't reversed.

An inlined-away original definition is never explicitly deleted here;
`Compiler.RC2.DeadCode` (already positioned later in the pipeline)
prunes it on its own once nothing reaches it anymore, the same as any
other unreachable definition -- unless something *else* still
references it (e.g. as a stored closure value, `RUnderApp`/
`RCConstClosure`, not a direct call), in which case it correctly
survives; this pass only ever removes the one call site it can prove
is the *only* one, never the definition itself.

### Eligibility -- and why it doubles as the profitability gate

A callee is inlined at its call site when, whole-program:

- it has *exactly one* `RAppName` occurrence anywhere (`analyse`'s own
  `callCounts`, built via `RCExp.idr`'s general-purpose
  `foldRCNamesD`/`RCNameFold` machinery rather than a bespoke walk);
- it's a genuine `MkRCFun` (not `RCCon`/`RCForeign`/`RCError`); and
- `callsBack` says the callee doesn't directly call the caller back --
  checked fresh at each individual splice decision, not (as originally
  shipped) by excluding whole-program cycle membership up front. See
  "Safe despite being part of a larger cycle" below for why this
  weaker, local, one-hop check is enough.

Unlike Criterion A, there's no separate size threshold. Single-caller
inlining is *unconditionally* safe to treat as profitable on its own:
since the callee has exactly one call site, splicing it there can
never increase the number of copies of that code anywhere in the
program -- at worst it's size-neutral (the call overhead itself is
removed, so in practice always a net win). A size cap only matters once
eligibility is ever widened to "small, multi-caller" callees (Criterion
A's own shape) -- not attempted here; see "Known limitations" below.

Processing runs in `tarjanSCCs`'s own reversed, callee-before-caller
order (the exact same `Graph`/`tarjanSCCs` reused from
`Compiler.RC2.MutualLoop`, `public export`ed there specifically for
this), rather than `defs`'s own incidental order -- so if `C`'s only
caller is `B`, and `B`'s only caller is `A`, processing `C` into `B`
*before* processing `B` into `A` means `A` receives the fully-collapsed
`B`-with-`C`-already-inlined in one pass, no re-run needed for the
whole chain to collapse.

### Safe despite being part of a larger cycle

Found against a real build, not constructed: compiling `idris2-lsp`
with `--directive dumprcexpr` turned up
`rc2_specClosure_Prelude_IO_map_Functor_IO:4852`, a `Compiler.RC2.
SpecClosure` clone with exactly one call site, three lines long, never
inlined. Tracing the whole-program `RAppName` graph by hand (grepping
the dump for `call NAME [` per definition) found why: it sits on a
real cycle --

```
:4852 -> rewriteSub:33 -> rewriteCExp -> rewriteSub
       -> rc2_specClosure_Core_Core__lt_star_gt:183 -> rewriteSub:36
       -> rc2_specClosure_Core_Core__lt_star_gt:181 -> rewriteSub:34 -> :4852
```

`Compiler.Opts.Constructor.rewriteCExp`/`rewriteSub` is a classic
recursive expression-tree rewriter; `SpecClosure` built clones at
several distinct points *inside* that same recursive structure, each
for a different closure target, so the clones ended up woven into the
cycle themselves. The original whole-program cyclic-SCC exclusion
correctly (if too bluntly) caught every one of them.

**The refined criterion.** A callee `b`, single-caller from `a`, is
safe to splice into `a` as long as `b` does not *directly* call `a`
back -- checked locally, one hop, fresh at each splice decision
(`callsBack`), rather than by excluding `b` for merely sitting
somewhere on a much larger cycle it has no direct part in closing.

**Proof.** Fix the invariant **I**: no function in the whole-program
call graph has a direct edge to itself. Splicing never renames a
call's own target `Name` (only the callee's internal `Int` var ids --
see "Every id gets renamed on the way in" below), so after splicing
`b` into `a`:

$$\text{outEdges}'(a) = \big(\text{outEdges}(a) \setminus \{a \to b\}\big) \cup \text{outEdges}(b)$$

The only edges newly added to `a`'s outgoing set are `b`'s own old
ones. `callsBack` requires $a \notin \text{outEdges}(b)$, so this union
still excludes $a \to a$. No other definition's own body is touched by
this splice. So **I** holds after the splice whenever it held before
-- by induction, it holds after any number of these splices, in any
order, to a fixpoint or otherwise. (**I** holds initially: `Compiler.
RC2.Loop`/`MutualLoop` already remove tail self-recursion into `RLoop`
before this pass ever runs, and a genuine non-tail self-call inflates
its own `callCounts` past 1 via its own `RAppName` occurrence, already
excluding it from `eligible` on that basis alone.)

**Walking the `a -> b -> c -> a` case.** `b` doesn't call `a` back
(only `c` does), so splicing `b` into `a` is allowed; the graph
shortens to `a -> c -> a`, a 2-cycle, still no self-loop. Now `c` *is*
single-caller (`a`) but *does* call `a` back directly -- `callsBack`
correctly refuses to splice it. The cascade halts exactly where
splicing would have produced a literal self-loop, never before.

**Not even load-bearing for runtime correctness.** `Emit.idr`'s own
`emitRC` never renders an `InTailPosition` `RAppName` as a real call at
all -- `tryBuildClosureInto` turns it into a closure build instead,
returned up to whichever ancestor call site is `NotInTailPosition` and
wraps its own call in `idris2rc2_trampoline(...)`, which dispatches
that closure (and whatever further closures dispatching it produces)
in a flat `while` loop, O(1) C stack regardless of how many times it
iterates. This is completely generic: it doesn't matter whether the
`RAppName` it's rendering existed before this pass ran, or was only
just created by splicing `c` into `a` moments ago. So even the one case
`callsBack` *does* still refuse -- `c` calling `a` back, which would
leave `a` with a brand new direct tail self-call after splicing --
would be runtime-safe if allowed: `a`'s own new tail position would
just become a closure build like any other, dispatched by whatever
called `a` from outside. `callsBack` forbids it anyway, purely to keep
`applyLateInline`'s own fixpoint loop from ever having to reason about
a function transiently holding a fresh self-loop mid-round -- whole-
program `callCounts` would disqualify such a function from `eligible`
again by the very next round regardless (its own new self-reference
counts as an occurrence), so skipping that detour costs nothing worth
having. A self-loop landing in *non*-tail position instead (also
possible, depending on where in `c`'s own body the call to `a` sat)
isn't covered by the trampoline at all -- but it isn't a new risk
either: a direct non-tail self-call just recurses through the ordinary
C call stack, exactly the same cost an unstructured non-tail-recursive
function already has with no inlining involved anywhere.

**Open question: native-typed tail positions, not checked.** The
argument above is about `RAppName` specifically, which is all this
pass ever sees -- `Compiler.RC2.LateInline` runs strictly before
`Compiler.RC2.DualABI`, so nothing here is `RAppNameRep` yet, and
every return type in play is still uniformly `RBoxed`. But splicing
can change the *shape* `DualABI` sees afterward: a caller `a` that
gains a callee's tail positions through this relaxed cyclic exclusion
might, post-splice, present `DualABI`'s own native-worker-eligibility
analysis (`tailValueReps`/`uniformTailType`) with a different tail-
position mix than `a` had standalone. If that analysis ever promoted
`a` to a *native*-returning worker over a tail position that still
structurally needs the trampoline treatment above (a `RLoop`-conversion
leftover, still relying on the closure-build fallback), there would be
nothing left to defer it as -- a native scalar can't represent "come
back later," only `RBoxed` can. `tailValueReps`'s own "every tail exit
agrees on the same type" uniformity check is presumably what would
catch a genuinely mixed case and refuse promotion, the same way
"Multiple loops per function" below turned out to already be handled
generically -- but this specific interaction (relaxed cyclic inlining
feeding into `DualABI`'s native-worker promotion) has not actually been
traced through or tested the way the boxed/trampoline case above has.
Treat it as unverified, not as cleared, until someone does.

### Iterated to a fixpoint, re-pruning dead code every round

Originally a single whole-program pass. `analyse`'s own `eligible` set
was computed once, from `defs` as they stood the moment this pass
started -- a callee that only becomes single-caller *after* this pass
already ran stayed undetected, since nothing re-derived `callCounts`
again within one round. `applyLateInline` now wraps the single-round
logic (`applyLateInlineOnce`) in a loop, re-running `analyse` from
scratch against the just-updated `defs` each time, until a round finds
nothing left to prune or splice, or `maxLateInlineIterations` (4, same
value and rationale as `RC2.idr`'s own `maxConstFoldIterations`) is
reached.

The fixpoint loop by itself only reaches a *narrow* class of new
opportunity -- one that genuinely only exists because of something
*this pass's own* splicing changed. A different, initially more
tempting case does *not* qualify: a callee with two call sites when
some round's own `analyse` runs, one of them inside a definition that
same round rewrites into unreachable dead weight. Nothing about
*inlining itself* deletes a definition from `defs` -- that stale call
site stays physically present, and `analyse`'s own `callCounts`
(`RAppName` occurrences, full stop) can't tell "still called" apart
from "called only from code nothing reaches anymore," so the callee
keeps looking "more than one caller" no matter how many further rounds
ran.

Fixed by having `applyLateInlineOnce` call
`Compiler.RC2.DeadCode.pruneDeadDefs roots` -- reused exactly as
`Compiler.RC2.DeadCode` itself calls it, `roots` threaded in as a new
parameter of both `applyLateInlineOnce` and `applyLateInline` -- as the
very first thing it does, every round, before `analyse` ever counts
anything. Deliberately *not* a reason to drop the later, separate
`pruneDeadDefs roots` call after `DualABI`: `DualABI` runs after this
pass entirely and can introduce fresh dead weight of its own (e.g. an
unused worker/wrapper split) that this pass can never see, so that
call stays exactly where it was. Also deliberately not a merge of this
pass's own eligibility graph with `pruneDeadDefs`'s own reachability
one into a single graph: `pruneDeadDefs`'s `usedFunctionNamesD` counts
`RUnderApp`/`RCConstClosure` references (a value only ever *stored* as
a closure, never `RAppName`-called) as genuine uses, on top of
`RAppName`/`RAppNameRep`, precisely so a function reachable only that
way survives -- `analyse`'s own `calleesOf`/`callOccurrencesOf`
deliberately don't (a stored-closure reference is never something this
pass could inline anyway), so reusing *that* narrower graph for
reachability would incorrectly prune a function still alive purely as
a closure value.

### Every id gets renamed on the way in -- including the callee's own internal ones

Splicing replaces a call's own top-level-argument-to-parameter binding
with an `RLet` per argument, and renames every occurrence of the
callee's own parameter id to that fresh `RLet`'s own id throughout the
spliced body (`Compiler.RC2.Loop`'s own `Renaming`/`renameRCExp`,
reused as-is). Two things about this are less obvious than they look,
both found as real bugs during implementation:

1. **Every argument gets a *fresh* id, even one that's already a bare
   `RCLoc` in the caller.** The tempting shortcut -- when the actual
   argument is already `RCLoc j`, just rename the parameter id directly
   onto `j`, skipping the `RLet` -- breaks the isolation an ordinary
   (non-inlined) call gives for free. A loop-converted callee's own
   `RLoop` commonly reuses its own top-level parameter's id as a
   *mutable* loop-carried variable (`Compiler.RC2.Loop`'s own "reuses
   its own id" case, `Emit.idr`'s own `declareLoopParam`); aliasing
   that id directly onto the caller's `j` lets the spliced-in loop
   reassign the caller's own variable in place. **Found via**: `map (*2)
   xs` immediately followed by `filter p xs` on the same `xs`, both
   single-caller-eligible and spliced back to back into the same
   caller -- `map`'s own loop mutated the shared `xs` variable down to
   `NIL` before `filter`'s own loop ever got to read it, since both had
   been renamed onto the very same id. `printLn (filter p xs)` printed
   `[]` instead of the correct result.
2. **The callee's own *internal* ids need renaming too, not just its
   top-level params** -- despite `Compiler.RC2.Util`'s own `VarId`
   counter already making every id globally unique from the moment
   it's first assigned (`rc2/doc/...` -- see that module's own doc
   comment). The exception: `Compiler.RC2.SpecClosure` builds *several*
   clones from one shared original body, rewriting only each clone's
   own apply-chain/self-call and leaving the rest of that body --
   internal ids included -- copied verbatim into *every* clone. Two
   such clones therefore legitimately share their own internal ids,
   harmlessly, as long as each stays its own separate C function (C
   scopes locals per function, so two unrelated functions can each
   have their own `var_301` with zero collision). Splicing two such
   clones into the *same* caller breaks that separation. **Found via**:
   two SpecClosure clones of the same original `String -> ... ->
   Boxed` helper (each with its own single call site), each containing
   an unrelated `let v301 = call Data.String.Iterator.fromString
   [...]` inherited verbatim from their shared original -- both spliced
   into the same caller produced two C declarations of `var_301` in
   one function (`error: redefinition of 'var_301'`).

`collectBoundIds` (this module's own copy -- `RLet`'s own `var`,
`RConAlt`'s own destructured `args`, `RLoop`'s own `loopParams`, the
same node shapes `Compiler.RC2.Loop`'s and `Compiler.RC2.MutualLoop`'s
own former copies of this covered before this session's `VarId`
unification made theirs unnecessary) finds every one of a callee's own
internal ids; each gets its own fresh id via `Compiler.RC2.Util`'s
`freshVarId`, merged into the same `Renaming` the parameter
substitution uses.

### Multiple loops per function

A caller that already has its own `RLoop` (its own self-recursion,
converted before this pass ever runs), inlining a *different*,
independently loop-converted callee into it, produces exactly the
"more than one `RLoop` in one function" shape
`rc2/doc/loop-conversion.md`'s "Multiple loops per function" section
made `Emit.idr` handle correctly -- no special-casing needed here:
`emitInto` already dispatches `RLoop` generically for any `sink`/
`TailPositionStatus`, so a loop-containing callee spliced in as an
ordinary `RLet` value (this pass's own default shape, see "Every id
gets renamed..." above) already lowers correctly, sibling or nested
alike.

### Fixed: DualABI's own native-eligibility analysis assumed one `RLoop` per function

`Compiler.RC2.DualABI`'s `findLoopThroughLets`/`paramEligibility` (its
own parameter-native-promotion decision) was written under a "one
`RLoop` per function" assumption that was true everywhere until this
pass existed -- both `findLoopThroughLets` (only ever found the first
`RLoop` reachable through a pure prefix of `RLet`s, stopping instead
of also looking for a further one nested inside its own body) and
`Loop.idr`'s own `nativeArgTypesFor`/`nativeArgTypes` (the fallback
`paramEligibility` uses when no such prefix-reachable loop exists at
all, e.g. because a `case` sits between the body's own root and the
loop -- the common shape once this pass can splice a loop-converted
callee in anywhere, not just at the root) had no `RLoop` case at all,
never recursing into one's own body.

Once this pass can splice a loop-converted callee into a caller that
may already have its own loop (see "Multiple loops per function"
above), either nested inside it or reached only past a `case`, a
top-level parameter used only natively *inside* that inlined-in loop
was invisible to both of `paramEligibility`'s own paths, and never got
promoted to a native worker argument -- confirmed real, not
hypothetical, by tracing through `DualABI.idr`/`Loop.idr` directly.

**Fix**: `nativeArgTypesFor`/`nativeArgTypes` (`Loop.idr`) now
recurse into an `RLoop`'s own `body` like any other wrapper node
(`loopParams`/`initial`/`prologueDrop` are metadata, not operations to
scan) -- this alone closes the gap for the common post-splice shape,
since `findLoopThroughLets` returning `Nothing` (anything other than a
pure `RLet`-prefix-then-loop) was already routing to this fallback.
`findLoopThroughLets` (`DualABI.idr`) also now recurses into a found
loop's own `body` for a *further*, genuinely nested loop, merging every
level's own `loopParams` together -- covering the case where
`paramEligibility` does still take its `Just` branch. A genuine
*sibling* loop (not nested, reached some other way after the first)
still can't be found this way regardless of the fix -- `RLoop` has no
"and then" field of its own to continue past -- but that shape was
already routing to the (now-fixed) fallback instead, never through
`findLoopThroughLets`'s own `Just` branch in the first place.
Re-verified against the full regression suite (85/0, 16/16) -- no
golden output needed regenerating, meaning nothing currently in the
suite actually exercises the gap this closed; the fix is aimed at the
`Compiler.RC2.LateInline`-enabled shapes it makes newly reachable.

### Fixed: a splice never propagated native-Rep, boxing-then-immediately-unboxing a provably-native value

Found while updating `rc2/BENCHMARKS.md` in a later session: `BenchChain`
(a self-recursive numeric loop calling a small non-recursive helper once
per iteration) and `BenchLoopCallArg` (an FFI-gated helper call whose
result feeds a loop's own accumulator) had regressed roughly 20-50x
versus their pre-`LateInline` baselines, *despite* every eligibility
check above being satisfied and the splice itself producing correct
output. Three distinct, layered manifestations of the same root cause,
each found via `--directive dumprcexpr` plus direct `time` comparison
against a `--directive nolateinline` build as the oracle:

**Layer 1 -- the callee's own substituted parameter.** `buildSplice`
binds each actual argument via a fresh `RLet`, whose own `Rep` `argRep`
picks from the *caller's* current `reps` environment (`RBoxed` unless
the caller already had it native) -- but the callee's own body was
annotated (Phase 2, before this pass ever runs, assuming the callee's
own top-level params are always `RBoxed`) with `RDup`/`RDrop`/postDrop
bookkeeping for a *Boxed* parameter. Declaring the fresh id `RNative`
outright without also stripping that bookkeeping is a real C compile
error (`idris2rc2_drop` given a raw `int64_t`); leaving it `RBoxed`
outright (the pre-fix behaviour) boxes an argument the callee's own
body only ever reads in native (`ROp`/`RCmpCase` operand) contexts,
forcing a box-then-immediately-unbox round trip on every use.

**Fix**: `nativeArgType` (`Loop.idr`, already existed, already
`RLoop`-aware) says what native type, if any, every native-context read
of a given id agrees on. A new `hasNonNativeUse ty loopSlots target e`
walks the callee's own body exhaustively and says whether `target` has
any occurrence *not* accounted for by a position `stripOwnership`
already knows how to clean up -- `RDup`'s own `v`, `RDrop`'s own `vars`,
`RFree`'s own `v`, and every node's own `postDrop` list are exempt (a
match there is stale bookkeeping, not a genuine need for boxing);
`RReleaseReuse`'s own `v` and `RReuseOffer`'s own `sc`/`dupOnShared`/
`dropOnUnique` are genuine disqualifying uses (`stripOwnership`
deliberately never touches an already-decided reuse); every other
structural position (a real operand of a call/con/struct op) is
genuine too. `nativeEligible paramId calleeBody` combines both:
`Just ty` only when `nativeArgType` and `not (hasNonNativeUse ...)`
agree. `buildSplice` then declares the fresh id `RNative ty` and
records it in a `promoted : SortedSet Int` set; `spliceCall` runs
`stripOwnership promoted` over the renamed body before splicing it in,
so the stale ownership nodes `hasNonNativeUse` exempted are actually
gone by the time the C emitter sees them.

**Layer 2 -- the caller's own `RLet` wrapping the call's result.** Even
with Layer 1 fixed, a call spliced directly as an `RLet`'s own value
(`let v = f x in ...`) kept that `RLet`'s own declared `Rep` exactly as
the caller's original (pre-`LateInline`) `annotate` pass decided it --
`RBoxed`, since nothing in the *original*, un-inlined program could
have known the callee's own tail value would turn out native. The
spliced-in body could be fully native internally and still get boxed
right back up the moment it reached that `RLet`.

**Fix**: `Compiler.RC2.DualABI`'s own `tailValueReps` (already existed,
already correctly answers "what native type, if any, does every tail
position of this whole expression agree on", including through
`RConCase`/`RConstCase`/`RCmpCase` branches and `RLoop` bodies) was
exported specifically for this reuse. A new `uniformTailType e` wraps
it (`Just ty` iff every entry is `Just ty`); `spliceCall` now also
returns this alongside the spliced expression. `inlineInto`'s own `go`
gained a case specifically for "call sits directly as an `RLet`'s own
still-`RBoxed` value": when the splice's own tail is uniformly native
*and* `hasNonNativeUse` (same check, now asked about `body` --
everything downstream of the `RLet` -- instead of a callee's own body)
finds no disqualifying use, the `RLet`'s own declaration is promoted to
`RNative ty` and `stripOwnership {var}` runs over `body`.

**Layer 3 -- the caller's own `RLoopContinue` receiving the result as
a loop accumulator.** Even with Layers 1-2 fixed, `BenchLoopCallArg`
(the call's result feeds directly into an enclosing `RLoop`'s own
`RLoopContinue ... args`, as the next iteration's accumulator) still
regressed. `hasNonNativeUse`'s original `RLoopContinue` case
conservatively treated *any* occurrence of `target` in `args` as
disqualifying, out of an unverified concern that the target slot's own
declared type might not match. Checked against `Emit.idr`'s own
`tryEmitLoopContinue`: it always renders a continue's new value via
`rcVarToNativeC`/`rcVarToBoxedC` keyed on the *target slot's own*
declared `Rep`, never the supplied value's own -- so a same-position,
same-type match is provably safe to promote.

**Fix**: `hasNonNativeUse` gained two new leading parameters, `ty` (the
candidate promotion type) and `loopSlots : List (Int, Rep)` (the
nearest enclosing `RLoop`'s own `loopParams`), and its `RLoopContinue`
case now only counts a position as disqualifying when that position's
`loopSlots` entry *isn't* already `RNative ty`. `inlineInto`'s own `go`
was extended with a third parameter threading the current enclosing
loop's own `loopParams` (`[]` outside any loop, set to `loopParams`
when `go`'s own `RLoop` case descends into `body` -- mirroring exactly
how `reps` is already threaded there), passed as `hasNonNativeUse`'s
starting `loopSlots` at both call sites (the callee-parameter check in
`nativeEligible`, which always starts at `[]` since a callee's own body
begins outside any *caller* loop context, and the `RLet`-direct-call
case in `go`, which needs the *caller's* current loop context). Passing
a hardcoded `[]` at the `RLet`-direct-call site (the shape actually hit
by `BenchLoopCallArg`, where the relevant `RLoopContinue` sits inside
an `RLoop` `go`'s own *outer* recursion had already walked through
before ever reaching this `RLet` -- not a *further* `RLoop` reachable
from `body` itself) silently kept the promotion from ever firing at all.

**A fourth bug found while fixing Layer 3**: promoting an `RLet` to
`RNative ty` purely because `uniformTailType` says every tail position
agrees on `ty` is *not* sufficient on its own -- `uniformTailType`
happily walks through `RConCase`/`RConstCase`/`RCmpCase` branches to
reach each one's own tail, but `Emit.idr`'s own `emitNativeValue` (the
single inline-C-expression renderer `declareNative`/`inlineNative` use
for an `RNative` local's own value) has no way to *render* a branch as
one C expression -- it only understands `RAppFFIInline`/`ROp`/
`RPrimVal` at the tail, unwinding `RLet`/`RDup`/`RFree`/`RDrop`/
`RReleaseReuse` wrappers on the way. Enabling Layer 3's extra promotions
newly exposed this: `Test15CompareFusionThroughCall`'s own `step`
(`if acc <= 0 then 1 else acc + 1`, spliced into a loop whose
accumulator feeds `RLoopContinue`) got promoted on `uniformTailType`
alone, then crashed `declareNative` with "[rc2] internal: expected a
native-producing expression" the moment its own `RCmpCase` reached the
emitter. **Fix**: a new `emitNativeValueCompatible e`, mirroring
`emitNativeValue`'s own supported-shapes list constructor-for-
constructor, gates the `RLet`-direct-call promotion alongside
`hasNonNativeUse` -- only a splice whose own tail, after unwinding the
same wrapper nodes `emitNativeValue` itself unwinds, bottoms out in
`ROp`/`RPrimVal`/`RAppFFIInline` (never a branch) is eligible.

Re-verified against the full regression suite (`rc2/tests/verify.sh`
85/0, `libs/rc2base/tests/verify.sh` 16/16) after every one of these
four fixes, plus direct `dumprcexpr`/`time` inspection of `BenchChain`
and `BenchLoopCallArg` against a `--directive nolateinline` build as
the correctness oracle. Final measured results: `BenchChain` 0.0052s
(125.31x vs RefC, exceeding its pre-regression historical record of
81.9x); `BenchLoopCallArg` 0.0032s (168.44x vs RefC, exceeding its own
historical baseline of ~66.7x).

### Fixed: constant closures and loop parameters (2026-09-26)

`buildSplice` records every argument that is a constant closure
(`RCConstClosure`) in `ConstClosureArgs`. `resolveConstClosureApps` then
rewrites an `apply` of that id in the spliced body into a direct call.
That id can also be one of the callee's loop parameters, though: its
constant is only the loop's *initial* value, and every
`RLoopContinue` rebinds it.

`Data.List.sort` hit exactly this. Its `splitRec` becomes a self-tail
loop that carries a difference list `zs` (`zs . ((::) y)`), started
from `id`. Once `splitRec` was spliced into `sortBy`, whose call
passes `id` literally, the base case `zs []` was rewritten into a call
to `id`. It returned `[]` instead of the elements the loop had
collected, so `sort [5, 3, 0, 9]` came out as `[9]`.

The rewrite has to stop at the loop boundary. Every `RLoop` case of
`resolveConstClosureApps` now removes that loop's own `loopParams`
from the map before it walks the body. The loop's `initial` list is
left alone, since it is read before the first iteration.

Why disabling other stages also hid the bug: `noloop` leaves no loop,
and `noconstfold` means the argument isn't a folded constant closure.
Regression test: `Test94LoopConstClosureParam`.

### Files

- `rc2/src/Compiler/RC2/LateInline.idr` -- this pass, in full.
- `rc2/src/Compiler/RC2/Loop.idr` -- `Renaming`/`renameRCExp`, reused
  as-is for the id substitution.
- `rc2/src/Compiler/RC2/MutualLoop.idr` -- `Graph`/`tarjanSCCs`, reused
  as-is for cycle exclusion and callee-before-caller ordering.
- `rc2/src/Compiler/RC2/RC2.idr` -- `toRCDefs`'s own wiring (between
  Loop conversion and Sink), `"nolateinline"` directive.

### Verification methodology

1. Full build + test suite: `rc2/tests/verify.sh` (85/0) and
   `libs/rc2base/tests/verify.sh` (16/16), both including `valgrind`.
2. Hand-written repro: a `go`/`mkTarget`-shaped self-recursive
   higher-order function, specialized by SpecClosure at two call sites,
   confirmed via `--directive dumprcexpr` to have both clones spliced
   directly into `main` (no longer present as separate top-level
   definitions), each its own `RLoop`/`loop_N:` label in the generated
   C, correct output unchanged.
3. `rc2/tests/refc-suite/callingConvention`'s own golden output needed
   regenerating for a reason *beyond* the usual cosmetic `var_N`/
   `tmp_N` renumbering this session's other changes also caused: this
   pass now inlines `sumLoop`/`eligibleAdd`/`tailAbs` away before
   `Compiler.RC2.DualABI` ever gets to synthesize a worker for them,
   so those worker functions genuinely stop existing as separate C
   functions. Confirmed the program's own stdout is unchanged
   (verified by running the binary directly, separately from the
   test's own C-source-structure assertions) before accepting the
   regeneration -- inlining removes the call boundary DualABI's own
   optimization was narrowing the cost of, so no longer needing that
   narrower optimization for these specific functions is expected,
   not a regression.
