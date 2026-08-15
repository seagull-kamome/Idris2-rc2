# TODO

Known gaps and future work for rc2, tracked here rather than only in
scattered code comments. Nothing below is a known correctness bug in
what's implemented -- see `rc2/tests/refc-suite/README.md` for bugs that
were found and already fixed.

## Performance: tail-position delegating calls stay boxed

Native type inference (`Compiler.RC2.Types`) only applies to values
that stay within a single function's ANF-normalized body -- every
function argument and return value used to always be boxed, meaning
native representations got boxed and reboxed at every call boundary.
Self-tail-calls sidestep this for loops specifically (see below), and
the dual calling convention (see below) closes the gap for essentially
every *non-tail-position* call boundary too. What's left, deliberately:
a **tail-position** call to a function with a native-signature worker
still goes through that function's own unchanged, fully-boxed wrapper,
permanently -- see `doc/dual-abi.md`'s own Stage 4 "Scope" section for
why (bypassing the closure-deferral/trampoline mechanism such a call
currently relies on to bound C stack growth would need real
interprocedural analysis this whole effort has otherwise avoided
needing). Believed comparatively rare in practice (a *pure* delegation
with no arithmetic of its own, e.g. `g x = h x`); revisit if profiling
ever shows otherwise.

`numeric.c`'s Boxed-value arithmetic/comparison/cast wrappers (the ones
called at every call boundary, where native inference doesn't reach)
are `static inline` in `numeric.h`, so the C compiler folds away their
own call overhead -- doesn't touch the actual (now largely closed)
boxing/reboxing gap above, just removes one small cost that used to sit
on top of it.

### Dual calling convention (implemented)

Lets native representations cross function boundaries for functions
where it's provably safe, via a worker/wrapper split (each eligible
function gets an internal native-signature worker alongside its
original, unchanged Boxed wrapper) plus whole-program call-site
rewriting for every non-tail-position call targeting one -- turned out
to need no whole-program fixed point at all, contrary to the original
escape-analysis-plus-fixed-point sketch this entry used to describe.
`fib 30`, timed directly against real `idris2 --cg refc`, runs roughly
35% faster. Full design, implementation walkthrough, and the bugs found
along the way (including two found only by reading generated C or
running it under `valgrind`, not by any stdout diff) are all documented
in **`rc2/doc/dual-abi.md`** -- moved there in full since it's finished
design/implementation, not an open gap; this entry is only a pointer.
The *loop-carried* subset of this same gap -- a self- or
mutually-tail-recursive loop's own parameters -- was addressed
separately (see `doc/loop-conversion.md`).

### Self-/mutual-tail-call loop conversion, native-shadow loop params (implemented)

Self-recursive and mutually-recursive tail calls compile to a plain C
`goto` instead of a closure + boxed trampoline (`Compiler.RC2.Loop`/
`Compiler.RC2.MutualLoop`), and a loop-carried parameter read as a
native-context numeric operand gets unboxed once at loop entry instead
of being re-boxed/re-unboxed at every iteration. Full design,
implementation walkthrough, and the bugs found along the way are all
documented in **`rc2/doc/loop-conversion.md`** -- moved there in full
since it's finished design/implementation, not an open gap; this entry
is only a pointer.

Its own known limitation used to be attributed to a `newtype`-style
single-field constructor wrapper never getting seen through for a
loop-carried parameter specifically -- **that diagnosis was wrong**.
Checked directly against `--directive dumprcexp` output: a genuine
`newtype`-eligible constructor is erased entirely by Idris2's own
frontend before rc2 ever sees it (both construction and matching --
upstream's own `LambdaLift.idr` doc comment: "backend implementations
needs not make use of \[the newtype info\], as newtype unboxing is
managed by the Idris 2 compiler"), so there was never a constructor
left for any rc2-side destructuring analysis to see through. The real
cause, confirmed by reproducing the identical symptom with a *plain*
`Bits64` parameter (no constructor at all), was a narrower bug in
`Compiler.RC2.Loop`'s own `nativeArgTypes`: a multi-operation ANF chain
(e.g. a hash-style `(v \`xor\` cast b) * k`) put the parameter's own
native-context read in an *inner* `RLet`'s `body` rather than directly
in an outer native-typed `RLet`'s `value`, which the scan never walked
into. Fixed by having `opNativeUsesThrough` also recurse through a
nested `RLet`'s own `body` (still gated by the outer, already-decided
native `Rep` -- an earlier, broader attempt that treated *any* bare
`ROp` as native regardless of enclosing context caused a real,
`valgrind`-caught leak in `Test9SelfTailLoop`, since a bare tail can
still genuinely render Boxed when `Compiler.RC2.Loop` itself runs,
before any function's return-eligibility has been decided). See
`rc2/tests/Test13NativeArgChain.idr` and `rc2/doc/loop-conversion.md`'s
own "Known limitation" section for the full writeup.

This fix closes the gap for a *non-loop* function's own parameters/
`Compiler.RC2.DualABI` worker eligibility (e.g. a `step`-shaped helper
called from within a loop). It does **not** by itself make a loop's own
carried accumulator skip boxing across iterations when that accumulator
is only ever passed *as a call argument* to such a helper (as opposed
to being read directly as an `ROp` operand inside the loop body itself)
-- `nativeArgTypes` still has no case recognizing "used as an argument
at a position a callee's own native-signature worker accepts natively"
as a native-context use. That remaining piece -- letting a loop
accumulator threaded only through helper calls still get shadow-
promoted -- is unaddressed and would need its own follow-on change
(teach `nativeArgTypes` about `RAppNameRep`/`callRep` argument
positions); not currently planned. The related but distinct gap for an
ordinary case-alternative's own destructured field (not loop-carried)
was addressed separately, see "Constructor-destructured field native
shadowing" below.

### Constructor-destructured field native shadowing (implemented)

Caches a constructor-destructured field read more than once in a
native context into a fresh native shadow, computed once
(`Compiler.RC2.ConAltNative`, a new pass running right after
`Compiler.RC2.Reuse`) -- reusing `Compiler.RC2.Loop`'s own existing
native-shadow-loop-param mechanism (mint a fresh id, `renameRCExp`
every reference to it, `stripOwnership` the now-stale bookkeeping that
rename carried along), just scoped to a single case-alternative's own
body instead of a whole function/loop. The field's own Boxed
declaration and its ownership/constructor-reuse-in-place participation
(`Compiler.RC2.RC`'s `annotate`, `Compiler.RC2.Reuse`'s `resolveAlt`)
stay completely untouched -- narrower in scope than the two-layer plan
this entry used to describe (a single-read field was already
effectively native today, via inline unboxing at that one read; only a
repeated read actually benefits from caching). Two implementation
attempts leaked (found via `valgrind`, not a stdout diff) before
landing on the version that shipped -- full design, both bugs, and the
fix are documented in **`rc2/doc/con-alt-native.md`** -- moved there in
full since it's finished design/implementation, not an open gap; this
entry is only a pointer. The *hoisting* extension the two-layer plan's
own second layer used to describe (loop-carried/dual-ABI-boundary
constructor state, not just a single alt's own body) was **not**
pursued -- left as plausible future work if profiling ever shows it
matters, not currently planned.

## Performance: constructor reuse doesn't reach across a monadic-bind continuation

Investigated why `Compiler.RC2.Reuse` doesn't fire on
`idris2-missing-containers`' `benchmarkHashMap` hot path (a bucket-list
`replaceL2` that destructures and reconstructs a same-shape `::` cell)
despite it being a textbook reuse candidate. Root cause confirmed via
`--directive dumprcexp`: the reconstruction happens inside a separately
lambda-lifted definition reached only through a genuine partial
application (a monadic-bind continuation, from `HasIO io =>`-polymorphic
`!`-bang-notation code -- not from `with` specifically, a case-based
rewrite of the same shape has the identical gap). `Reuse`'s own
eligibility check is intentionally, purely intraprocedural (any call is
a dead end); a proposed fix (inline single-call-site, fully-saturated-call
definitions before `Reuse` runs) is sound in principle but doesn't reach
this specific case, since the call in question is a genuine partial
application, not a fully-saturated one. Not pursued further -- full
investigation, both refuted hypotheses, and what a real fix would need
are in **`rc2/doc/reuse-monadic-bind-gap.md`**.

## Performance: interface-dispatched comparisons never fuse into RCmpCase

`Compiler.RC2.RC`'s `tryFuseCompare` only fuses a *direct* primitive
comparison immediately consumed by a two-way Bool match into a single
`RCmpCase` -- when the comparison is reached through an interface method
call instead (e.g. `n <= 0` via `Ord Int`'s `<=`, a genuine, statically-
resolved top-level function -- confirmed no dictionary parameter, since
only fixed-width scalar types are ever native-eligible to begin with),
this never fires: the comparison sits inside `<=`'s own separate
definition, invisible to the caller's own fusion analysis. Confirmed via
`--directive dumprcexp` that `<=`'s own Dual-ABI worker, in isolation,
*does* already fuse correctly (its own body is `cmp <=Int [...] then 1
else 0`) -- the gap is purely "the caller doesn't see through the call
boundary."

Investigated a general whole-program, `Lifted`-to-`Lifted` inlining pass
(`Compiler.RC2.Inline`, run before `RC.idr`'s own Phase 1) meant to close
this by splicing a small/single-call-site callee's own body into its call
site (plus a `Compiler.CaseOpts`-style case-of-case collapse, needed for
`tryFuseCompare` to then fire unmodified). Built, wired in, and initially
verified working via `--directive dumprcexp` (the call and boxed Bool
both disappear, replaced by one native `RCmpCase`) with correct output
and zero leaks on the motivating test case -- but the full regression
suite then surfaced a real, `valgrind`-confirmed per-loop-iteration leak
in `Test9SelfTailLoop`'s own `collatzLike`. First investigation session
ruled out the case-of-case collapse (disabling it entirely didn't change
the leak) and, unable to find the real cause, reverted the pass in full
(no `Compiler.RC2.Inline` code or commit kept) rather than ship a known,
unexplained leak.

**Root cause since found and fixed, independently of the inlining pass**
(see `rc2/doc/loop-conversion.md`'s "Bugs found and fixed" #5 for the
full write-up) -- two separate, pre-existing bugs, both on the shape "a
`case`/`if`-valued `RLet` whose overall Rep `Types.repOf` never promotes
to Native, feeding a native-shadowed loop parameter's next value," which
the inlining pass's own comparison-fusion happened to newly produce for
the first time:
- `RLoopContinue` had no `postDrop` field, unlike every other RCExp
  construct that reads a Boxed value natively -- fixed by adding one,
  filled in by `Compiler.RC2.Loop`'s new `fillLoopContinuePostDrop`.
- `Compiler.RC2.Emit`'s `ROp` case fabricated an anonymous, unfreed
  Boxed wrapper (`rcVarToBoxedC`'s own `nativeMk`) whenever a Boxed-
  result op read an individually-Native operand -- fixed by `boxOpArg`,
  which names and drops that ephemeral box.

Both fixes are general rc2 pipeline fixes (not specific to inlining) and
are verified clean across the full regression suite plus a dedicated
test, `rc2/tests/Test16LoopContinuePostDrop.idr`. The minimal repro from
the original investigation, confirmed clean post-fix:
```
step : Int -> Int
step acc = if acc == 0 then 1 else acc + 1

loop : Nat -> Int -> Int
loop Z acc = acc
loop (S k) acc = if acc == (-999999) then acc else loop k (step acc)
```
compiled with `step` inlined into `loop`'s own recursive-step argument
(so both `if`s end up native-comparison-fused, independently, within the
same loop iteration) -- previously leaked roughly two allocations per
iteration under `valgrind --leak-check=full`, now zero.

**`Compiler.RC2.Inline` itself is still not re-implemented** -- the gap
this section opened with (interface-dispatched comparisons never fusing
into `RCmpCase`) remains open. With the root cause above now fixed and
out of the way, re-attempting the inlining pass is unblocked.

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
