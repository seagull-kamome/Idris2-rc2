# TODO

Known gaps and future work for rc2, tracked here rather than only in
scattered code comments. Nothing below is a known correctness bug in
what's implemented -- see `rc2/tests/refc-suite/README.md` for bugs that
were found and already fixed.

## Performance: calling convention stays fully boxed

The biggest lever left on the table. Native type inference
(`Compiler.RC2.Types`) only applies to values that stay within a single
function's ANF-normalized body -- every function argument and return
value is always boxed, so native representations get boxed and reboxed
at every call boundary. Self-tail-calls (see below) sidestep this for
loops specifically -- a loop's own parameters never actually leave a
single C stack frame -- but any *other* call boundary (a non-tail call,
a call to a different function, a mutually-recursive cycle) still pays
full boxing/reboxing cost.

`numeric.c`'s Boxed-value arithmetic/comparison/cast wrappers (the ones
called at every call boundary, where native inference doesn't reach)
are now `static inline` in `numeric.h`, so the C compiler folds away
their own call overhead. This doesn't touch the actual bottleneck --
the heap allocation and refcount bookkeeping the boxed representation
itself requires -- so it doesn't reduce the gap below; it only removes
one small, now-irrelevant-by-comparison cost that used to sit on top
of it.

- **Dual calling convention.** Let native representations cross function
  boundaries for functions where it's provably safe (escape analysis +
  a fixed-point signature inference pass, plus native entry points
  alongside the existing boxed ones so external/FFI/dynamic-dispatch
  call sites keep working). This was scoped out of the current
  iteration as too large/risky to do alongside the RC-as-separate-pass
  work; see the project plan for the original design sketch. The
  *loop-carried* subset of this gap -- a self- or mutually-tail-
  recursive loop's own parameters -- is now addressed separately (see
  "Native-representation loop-carried parameters" below); this bullet
  is about the remaining, more general case: an ordinary (non-loop)
  call boundary between two different functions.
### Self-tail-call loop conversion (implemented)

A function's own self-recursive tail calls compile to reassigning its
parameter variables and a plain C `goto` back to the top, instead of
building a closure and going through the generic boxed trampoline --
`Compiler.RC2.Loop`, a dedicated pass mirroring `Compiler.RC2.Reuse`'s
place in the pipeline (runs on the fully Phase-1+2'd, Reuse'd tree,
right before Emit). The decision and the `RLoop`/`RLoopContinue` nodes
it introduces live entirely in the IR; `Compiler.RC2.Emit` only lowers
them (`emitLoopInto`/`tryEmitLoopContinue`, alongside
`tryBuildClosureInto`'s existing "try the tail-position special case
first" protocol). Scope: self-only (mutual recursion between two or
more functions is `Compiler.RC2.MutualLoop`'s job, see below), and
calls under a `LazyReason` are excluded (conservative). Ownership is
untouched by the wrapping rewrite itself -- `annotate` (Phase 2)
already decided each argument's dup/move before this pass ever runs,
exactly as for a call to any other function; only the *shape* of the
call changes. `BenchFib.idr`'s naive `fib` is *not* tail-recursive
(both recursive calls are inside a `+`) and is correctly left
unconverted -- still bound by the calling-convention gap above.

### Native-representation loop-carried parameters (implemented)

Builds on the `RLoop`/`RLoopContinue` split above: each loop param
carries its own `Rep`, independent of the enclosing function's
always-Boxed calling convention (`RCExp.idr`'s own doc comment on
`RLoop` spells out why this shape was chosen). `Compiler.RC2.Loop`'s
`applyLoop` now decides, per top-level parameter, whether the
(rewritten) loop body reads it as a native-context operand anywhere
(an `RLet`-bound `RNative`/`RInlineNative` `ROp`, or a fused
`RCmpCase` -- the only two places `Compiler.RC2.Emit` ever reads an
operand via `rcVarToNativeC` rather than `rcVarToBoxedC`) consistently
at one `PrimType` (`nativeArgType`); if so, a fresh loop param id is
minted, `RNative` at that type, and every other reference to the
original (still-Boxed) parameter throughout the body is redirected to
it (`renameRCExp`, shared with `Compiler.RC2.MutualLoop`'s own
per-member renaming) with the original's now-stale ownership footprint
(`RDup`/`RDrop`/`RFree`/`postDrop` entries `annotate` had decided back
when it was read from multiple Boxed-context sites) stripped out
(`stripOwnership`) -- a native value never needs any of that. The
original parameter is unboxed exactly once, at loop entry
(`Compiler.RC2.Emit`'s `declareLoopParam`), and dropped there if it was
Boxed; every within-loop use, across every iteration, then reads/writes
the native shadow directly, with no re-boxing/re-unboxing round trip at
the `goto`. A parameter never read natively, or read natively at
conflicting types, stays `RBoxed` (unaffected). This also incidentally
fixes *within-iteration* redundant unboxing of a multiply-used native
operand (previously unboxed once per read site).

Two real bugs surfaced during verification, both fixed:
- `RConstCase`'s scrutinee handling (`emitConstCaseInto`) assumed its
  scrutinee was always read Boxed (`idris2rc2_extractInt`-style
  extraction, or a boxed-struct field dereference for `Double`
  literals) -- true for every case Phase 1/2 produce on their own, but
  not once a loop param pattern-matched against literal constants (a
  countdown's own `0` check, e.g. `BenchLoop.idr`'s `sumTo`) could
  become a native shadow. Now Rep-aware in both its integer-switch and
  string/double-equality-chain paths.
- `Compiler.RC2.MutualLoop`'s own arity-padding (`RCNull`, standing in
  for a smaller-arity member's unused trailing slot) could reach a
  parameter some *other* member of the same merged group reads
  natively, promoting that slot to `RNative` group-wide.
  `Compiler.RC2.Loop` has no visibility into MutualLoop's own padding,
  so it can't exclude this from eligibility; unboxing it (at loop
  entry, or via `Compiler.RC2.Emit`'s `tryEmitLoopContinue` mid-loop)
  dereferenced that `NULL`, a real crash `Test10MutualLoop.idr`'s own
  differing-arity group (`stepA`/`stepB`) caught. Fixed with two small,
  narrowly-scoped guards: `rcVarToNativeC` treats `RCNull` as a plain
  native `0` (never dereferenced -- MutualLoop's own invariant
  guarantees a padding slot is never actually *read* on the path that
  receives it, so any value is safe there), and `declareLoopParam`'s
  loop-entry unboxing gets a one-time runtime `NULL` guard (negligible
  cost -- once per call, not once per iteration).

`BenchLoop.idr` (`sumTo`, tail-recursive) now runs its entire loop body
-- both parameters -- as pure native `int64_t` arithmetic with zero
heap allocation and zero refcount traffic per iteration, boxing only
once at entry (from the caller) and once at exit (the return value);
`BenchChain.idr`'s `loopPoly` (also tail-recursive) sees the same
effect. Verified: generated C for `BenchLoop.idr`/`Test9SelfTailLoop.idr`
(mixed native-eligible/non-native-eligible params in the same loop,
e.g. `countDown`'s `Int` counter alongside its `String` passthrough)
inspected directly; 19/19 refc-suite tests, all smoke tests
(`Test1Basics.idr`-`Test10MutualLoop.idr`), and all benchmarks re-verified
byte-for-byte/crash-free against `idris2 --cg refc` after both bugfixes.

### Mutual tail recursion loop conversion (implemented)

The same idea as self-tail-call loop conversion, extended to a cycle of
two or more mutually tail-recursive functions instead of a single
function calling itself. New whole-program pass `Compiler.RC2.MutualLoop`
runs after `Reuse` and before `Loop` (see `RC2.idr`'s `toRCDefs`): finds
groups of >= 2 functions that mutually tail-call each other (Tarjan's
SCC over the tail-call graph, so indirect cycles are found too, not
just direct pairs -- lazy calls excluded, matching `Loop`'s own
restriction), and merges each group into a single synthesized function
whose body is an `RConstCase` switching on a small integer tag (one alt
per original member). Every internal transition (self- or cross-member)
is rewritten into an ordinary tail call to that merged function itself
-- from the merged function's own point of view that's just a ordinary
self-tail-call, so `Compiler.RC2.Loop` (running immediately after)
converts it to a `goto` automatically, with zero new logic needed in
`Compiler.RC2.Loop` or `Compiler.RC2.Emit`. Each original member name
becomes a thin wrapper that calls the merged function once. Ownership
carries over via pure id-renaming (each member's own top-level
parameters and internal let/pattern-bound ids get renamed onto shared
`tag, slot_0 .. slot_k` ids, k = the largest arity in the group) rather
than a fresh ownership decision -- `annotate` (Phase 2) already decided
every member's own dup/drop/move behaviour before this pass ever runs.
Members with a smaller arity than the group's max simply never
reference their own unused trailing slots; every transition always
pads them with `RCNull`, which needs no extra drop logic given the
inductive invariant that a member's own slots beyond its own arity are
always null. (This padding interacts with native-representation loop
params in a way that needed its own fix -- see "Native-representation
loop-carried parameters" above.)

Verified with `Test10MutualLoop.idr` (reusing Test9SelfTailLoop's own
`isEvenM`/`isOddM`, specifically written to confirm mutual recursion
was *not* touched by the self-tail-call-only pass -- now the first real
test that it *is* merged and converted): differing-arity group members
(slot padding), a 3-way cycle (SCC beyond the trivial pairwise case), a
same-member transition inside a merged group (not just cross-member), a
group member called both non-tail and as a first-class closure value
from outside the group, and 300,000-500,000-deep mutual recursion with
no stack growth. Output matches `idris2 --cg refc` byte-for-byte;
inspected the generated C directly for the expected shape (`loop:;` +
`goto loop;` for every internal transition, correct tag dispatch,
correct slot padding). 19/19 refc-suite tests and all other smoke tests
still pass and still match upstream byte-for-byte.

## Scope: deliberately unboxed types stop at scalars

`Integer` (GMP arbitrary precision) and `String` are never candidates
for native-representation inference -- only fixed-width numeric types
(`Int`, `Bits8`/`16`/`32`/`64`, `Int8`/`16`/`32`/`64`, `Double`, `Char`).
This is a deliberate scope boundary, not a bug, but revisiting it (e.g.
a native "small string" representation) is plausible future work if
profiling ever shows it matters. Comparison/branch fusion (`RCmpCase`,
see `Compiler.RC2.RC`'s `tryFuseCompare`) follows the same boundary --
`LT`/`GT`/`EQ`/`LTE`/`GTE` over `Integer` or `String` still always
materialize a boxed `Bool`, even when immediately consumed by a branch;
only comparisons over the fixed-width/`Double`/`Char` types above skip
that materialization.

## Architecture: one optimization decision still lives in Emit.idr

`Emit.idr`'s own module note claims it's purely mechanical -- every
ownership/native-vs-boxed decision already made by `Compiler.RC2.RC`
and lowered as-is. One spot (value-based, not shape-based, which is
why it wasn't folded into the same elevation as `ROp.postDrop`/
constructor-reuse/single-use closure-building) doesn't actually fit
that description yet:

- **Small-int cache / constant-staging threshold** (`RPrimVal`'s
  `dyngen`/`orStagen` in `Emit.idr`): decides, based on a literal's
  *value* (`[0,100)` for the small-int cache; `ConstDef`/`SortedMap`
  keyed staging to deduplicate repeated same-value boxed constants)
  which representation strategy to use, entirely at emission time.
  Elevating it would mean `RC.idr`'s Phase 1 either duplicating
  knowledge of the small-int cache range, or `Emit.idr` keeping a
  genuinely emission-scoped concern anyway (constant deduplication
  naturally wants a single table spanning the *whole compiled file*,
  not per-definition, so it doesn't fit the "decide once per node
  during Lifted -> RCExp conversion" pattern the other elevations use).
  Not obviously wrong to leave as-is; flagged for a decision, not a
  known bug.

(`keepBoxedLocals`'s filter, previously flagged here as possibly fully
dead code, was confirmed dead by exhaustively tracing every site that
adds to `Owned` in `RC.idr` -- all three only ever insert genuine
`RCLoc`s already excluded from `natives` -- and removed.)

## Concurrency: unchanged from RefC

Reference counting stays non-atomic, matching RefC's own single-threaded
assumption. If rc2 ever needs to support genuinely concurrent mutation
of shared values, this needs revisiting (atomic refcounts at minimum,
possibly a different GC strategy). Not addressed, not currently planned.

## Test coverage gaps

Two of upstream Idris2's own `tests/refc/*` regression tests were
deliberately not ported (see `rc2/tests/refc-suite/README.md` for the
full reasoning):

- **`ccompilerArgs`**: verifies that `CFLAGS`/`LDFLAGS`/`LDLIBS` env vars
  reach the C compiler invocation. `Compiler/RC2/CC.idr` has equivalent
  flag-handling logic, but it's currently *unverified by a test* --
  porting upstream's test faithfully (its own companion C library,
  env var wiring) was judged out of proportion to do alongside the rest
  of the regression-suite port. Worth doing as a focused follow-up.
- **`callingConvention`**: upstream's version `awk`-inspects the shape
  of RefC's own generated C, which isn't meaningful for rc2's
  structurally different codegen. No rc2-specific replacement exists
  yet that would pin down the *current* (fully-boxed) calling
  convention's C shape as a regression guard -- worth writing from
  scratch, especially before starting on the dual-ABI work above (so
  there's a test to update/extend rather than write from nothing once
  the convention actually changes).

## Runtime: RFree rarely fires in practice

`RFree` (unconditional, unchecked deallocation for provably-fresh
unshared allocations) is implemented and type-checks/reviews fine
structurally, but was observed to essentially never appear in generated
code for ordinary Idris2 source: Idris2's own frontend multiplicity-based
dead-code elimination removes the only kind of binding
(`dropDeadLet`'s target: a let-bound value that's never used) that would
trigger it, before `RC.idr` ever sees it. Confirmed this is inherent to
upstream Idris2's pipeline, not rc2-specific (RefC has the same
non-firing behavior for the same reason). Not a bug to fix, but noted
here in case a future frontend change or a different lowering strategy
changes when `RFree` becomes reachable, so its rarely-exercised code path
gets renewed scrutiny then.
