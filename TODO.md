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

- **Dual calling convention (in progress, branch `dual-abi`).** Let
  native representations cross function boundaries for functions where
  it's provably safe, via a worker/wrapper split (each eligible
  function gets an internal native-signature worker alongside its
  original, unchanged Boxed wrapper) -- turned out to need no
  whole-program fixed point, contrary to the original escape-analysis-
  plus-fixed-point sketch this bullet used to describe. Implemented and
  verified so far: the IR foundation, local per-function eligibility
  analysis, and worker/wrapper synthesis for both *parameters* and
  *return values* (`Main.fib`'s own worker is now `int64_t
  rc2_dualABI_N(int64_t)`, native end to end). Still missing: rewriting
  call sites throughout the program to actually target a worker
  directly (today every call still goes through the unchanged wrapper,
  so there's no performance change yet -- that's the whole remaining
  gap). Full design, implementation walkthrough, and bugs found along
  the way are in **`rc2/doc/dual-abi.md`**, including exactly what's
  implemented versus still planned. The *loop-carried* subset of this
  gap -- a self- or
  mutually-tail-recursive loop's own parameters -- was addressed
  separately (see `doc/loop-conversion.md`).

### Self-/mutual-tail-call loop conversion, native-shadow loop params (implemented)

Self-recursive and mutually-recursive tail calls compile to a plain C
`goto` instead of a closure + boxed trampoline (`Compiler.RC2.Loop`/
`Compiler.RC2.MutualLoop`), and a loop-carried parameter read as a
native-context numeric operand gets unboxed once at loop entry instead
of being re-boxed/re-unboxed at every iteration. Full design,
implementation walkthrough, the bugs found along the way, and a known
limitation (native-shadow eligibility doesn't currently see through a
`newtype`-style single-field constructor wrapper) are all documented in
**`rc2/doc/loop-conversion.md`** -- moved there in full since it's
finished design/implementation, not an open gap; this entry is only a
pointer.

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
