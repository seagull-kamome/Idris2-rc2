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
`MutualLoop.idr` in case a future session revisits this.

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
- it isn't part of any cycle in the whole-program `RAppName` call graph
  -- a size->=2 Tarjan SCC, or a direct self-edge (the latter catches a
  function that's still directly self-recursive at this point in the
  pipeline, e.g. a non-*tail* self-call `Compiler.RC2.Loop` never
  touches -- inlining that would splice an unbounded copy).

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

### Known limitation: DualABI's own native-eligibility analysis

`Compiler.RC2.DualABI`'s `findLoopThroughLets`/`paramEligibility` (its
own parameter-native-promotion decision) was written under a "one
`RLoop` per function" assumption that was true everywhere until this
pass existed: `findLoopThroughLets` only ever finds the *first* `RLoop`
reachable through a pure prefix of `RLet`s, and `Loop.idr`'s own
`nativeArgTypesFor`/`nativeArgTypes` (the fallback `paramEligibility`
uses when no such prefix-reachable loop exists) has no `RLoop` case at
all -- both were correct when nothing but `Compiler.RC2.Loop` itself
(this pass's own sole producer, at the time) ever saw an `RLoop`-
containing body.

Once this pass can splice a loop-converted callee into a caller that
may *already* have its own loop (see "Multiple loops per function"
above), a top-level parameter used only natively *inside* an inlined-
in loop -- rather than directly in the caller's own original code --
is now invisible to both of `paramEligibility`'s own paths, and never
gets promoted to a native worker argument. This is a real, confirmed
gap, not hypothetical (traced through `DualABI.idr`/`Loop.idr`
directly) -- tracked as a follow-up fix to `findLoopThroughLets`/
`nativeArgTypesFor` rather than addressed in this pass, since it's a
pre-existing assumption in a different, already-delicate module, not
something specific to how this pass itself splices.

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
