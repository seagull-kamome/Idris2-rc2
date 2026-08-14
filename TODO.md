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
is only a pointer. Its own known limitation (native-shadow eligibility
doesn't currently see through a `newtype`-style single-field
constructor wrapper) is being generalized into its own planned work,
see "Native representation for constructor-destructured fields" below.

### Native representation for constructor-destructured fields (planned, not started)

Found while discussing further optimization candidates after
`BENCHMARKS.md`'s own `idris2-missing-containers` re-measurement (its
"ループ変数のネイティブ表現化" section found the hash-algorithm state --
a single-field wrapper around a `Bits32`/`Bits64` -- can't currently
become a native shadow, exactly the loop-conversion `newtype`
limitation above). Looking into it turned up a more fundamental, more
broadly useful gap than that limitation alone suggested.

**The actual current gap, confirmed by reading the code directly:** a
case-alternative's destructured fields (`RConAlt`'s own
`args : List Int`, bound by `RC.idr`'s `normalizeConAlt`) never go
through `Types.idr`'s `repOf`/Rep-inference machinery at all -- `repOf`
only ever looks at `RLet`/`ROp`/`RPrimVal`, `normalizeConAlt` builds no
`Rep` for its fresh `argIds`, and `Emit.idr`'s `emitConAltBody`
unconditionally declares every destructured field `IDRIS2RC2_Value *`
(Boxed), never consulting `RepMap`. This holds regardless of how many
alternatives the enclosing `RConCase` has, or whether the scrutinee's
type is single- or multi-constructor -- an ordinary, already-tag-checked
pattern-match body (`case acc of MkAcc x y => ... x ...`, an everyday
two-field record, not just a `newtype`) gets zero benefit from native
inference on its own bound fields today.

**Planned in two layers:**

1. **Base fix (no type-table lookup needed, no alt-count/default
   condition needed):** extend Rep inference to case-alternative-bound
   locals the same way `RLet`-bound locals already get it. Being inside
   a given alternative's own body is *already* proof the scrutinee's tag
   matched that alternative's constructor -- unconditionally, regardless
   of how many other alternatives exist or whether a default branch is
   present -- so no new safety argument is needed here, only wiring:
   `normalizeConAlt`/whatever downstream pass decides Rep would need to
   ask the same "is this field consistently read in a native context
   within the alt's own body" question `Types.repOf` already asks for
   `RLet` values, and `Emit.idr`'s `emitConAltBody` would need to
   consult `RepMap` the way `RLet`'s own declare path already does. This
   alone should unlock native field access for any *already-written*
   `case`/pattern-match in ordinary source, single-constructor or not
   (the hash-algorithm-state case above, and plain multi-field
   records/product types generally).
2. **Hoisting extension (loop-carried state / function-boundary
   arguments; needs the single-constructor safety argument):** for a
   loop-carried value or a dual-ABI-eligible argument that's read via a
   `case` *every iteration/every call* rather than once, hoist the
   tag-check-and-destructure to loop-entry/function-entry (mirroring
   `Loop.idr`'s existing `declareLoopParam`, which already does exactly
   this for raw-scalar loop params). Safe *without* consulting the
   scrutinee's own type declaration at all -- purely from the existing
   `RConCase`'s own shape: exactly one alternative (`List RConAlt` of
   length 1) **and** no default branch (`Maybe RCExp` is `Nothing`) is
   the only shape Idris2's own case-tree compiler ever produces for an
   exhaustive match, which only happens when the type genuinely has one
   constructor. (A single alternative *with* a `Just` default -- e.g.
   matching only `Just x` of a `Maybe` -- does *not* qualify: the alt's
   own body is still safely tag-checked by layer 1 above, but the type
   isn't provably single-constructor, so hoisting the check itself out
   of the loop/before the call wouldn't be sound.)

**Files likely involved:** `rc2/src/Compiler/RC2/RCExp.idr`
(`RConCase`/`RConAlt` definitions -- no change expected, the existing
shape already carries everything layer 2 needs), `Types.idr` (`repOf`
extension), `RC.idr` (`normalizeConAlt`), `Emit.idr`
(`emitConAltBody`'s `RepMap` consultation), `Loop.idr`
(`declareLoopParam` as the precedent layer 2 would mirror),
`DualABI.idr` (layer 2's own argument-eligibility side, if pursued for
function boundaries too, not just loops).

**Correction (first implementation attempt, reverted -- see below):**
layer 1's own premise above -- "no new safety argument needed, just
wiring" -- turned out to be wrong on the ownership side specifically,
found empirically (this project's own standing discipline: a stdout
diff alone doesn't catch a reference-counting bug, `valgrind
--leak-check=full` does, exactly as it did for `doc/dual-abi.md`'s own
bug #3). A first attempt changed `RConAlt`'s `args` to
`List (Int, Rep)`, excluded native-Rep fields from `annotate`'s own
`owned` set (mirroring an `RLet`-bound native local exactly) and from
`Compiler.RC2.Reuse`'s own `dupOnShared` computation, and declared a
native field by unboxing `sc->args[k]` directly at destructure time,
discarding the boxed pointer. Every field is still *physically* stored
Boxed inside a constructor (`sc->args[k]` is always
`IDRIS2RC2_Value *`, native or not) -- unlike an `RLet`-bound native
value, which genuinely has no Boxed source anywhere to release, a
destructured field's own **origin** (the Boxed value sitting in the
constructor's own storage slot) still needs exactly one
`idris2rc2_drop` somewhere, or it leaks -- confirmed with a dedicated
test (`Acc = MkAcc Int Int` destructured and immediately reconstructed
in a 200k-iteration self-tail-recursive loop, deliberately chosen to
also exercise `Compiler.RC2.Reuse`'s constructor-reuse-in-place path
alongside the new native fields): `valgrind` reported ~6.4MB
definitely lost, one full `idris2rc2_mkInt64` allocation leaked per
iteration. Root cause: in the *ordinary* (pre-this-change) design, a
Boxed destructured field participates fully in `annotate`'s normal
owned/dead-variable tracking, so an explicit `RDrop` releases its own
Boxed origin once it's read for the last time -- excluding it from
`owned` entirely (as a native local legitimately can, since *it* has no
Boxed origin to release) silently deleted that drop instead of
replacing it with anything. In the constructor-reuse path specifically
(`sc`'s own storage reused in place rather than dropped), nothing else
ever recovers that leaked reference either -- `sc` itself is never
dropped there by design.

This reopens what layer 1 actually needs to be: not "exclude the field
from ownership like a genuinely native local," but something closer to
`ROp`'s own `postDrop` -- the field's Boxed origin keeps participating
in ownership/reuse tracking exactly as today, and the *optimization* is
narrower than originally scoped: `rcVarToNativeC` already unboxes a
still-Boxed local inline at each native-context read (its own `RBoxed`
case, `nativeUnbox ty (...)`) -- a destructured field read exactly once
natively is *already* effectively native today, at the cost of one
inline unbox per read, with correct ownership for free (nothing to do
there). The real remaining gap is narrower: caching that unboxed value
once, across a field read *more than once* natively within the same
alt, instead of repeating `idris2rc2_to_i64(...)` at every read --
while leaving the field's own Boxed declaration/`RDrop`/reuse
participation completely untouched, unlike the reverted attempt above.

All changes from the first attempt were reverted (`git checkout --`)
rather than fixed forward, to leave a known-good baseline; nothing from
that attempt is in `master`.

**Revised layer 1 mechanism (planned, not yet attempted): mint a
native shadow and rename into it, exactly `Compiler.RC2.Loop`'s own
existing native-shadow-loop-param trick, just scoped to a single alt's
own body instead of a whole function/loop.** `Loop.idr` already solves
precisely this "redirect every native-context read of a Boxed value to
a cached native copy, without disturbing the original's own ownership
except where its own use sites actually changed" problem for top-level
parameters -- reuse its shape rather than re-deriving a new one:

1. Run as a **new pass, after `Compiler.RC2.Reuse`** (so `resolveAlt`'s
   own `dupOnShared`/`RReuseOffer` decisions are already finalised
   around the field exactly as they are today, completely undisturbed
   -- this new pass only ever *adds* a wrapping `RLet`, never touches
   an existing ownership node). Ordering relative to
   `Compiler.RC2.Loop`/`MutualLoop`/`DualABI` otherwise probably
   doesn't matter for this layer alone (no loop/call-boundary hoisting
   yet, that's layer 2) -- confirm empirically once implementing rather
   than assuming.
2. For each `RConAlt`, ask `nativeArgType argId altBody` (unchanged --
   the same usage-scan already planned above, and already exported for
   reuse). If it finds a consistent native type `ty`:
3. Mint a fresh id `shadowId`, and wrap the alt's own body in
   `RLet shadowId (RNative ty) (RV (RCLoc argId)) body'` -- a
   *manually*-assigned `Rep`, the same way `Loop.idr`'s own
   `declareLoopParam`/`Compiler.RC2.DualABI`'s own worker synthesis
   already bypass `Types.repOf`'s ordinary "only `ROp`/`RPrimVal`
   propose Native" rule for a value they already know is safe to
   declare native (`repOf` alone would leave a bare `RV` passthrough
   `RBoxed`, per its own doc comment). `Emit.idr`'s `declareLet`
   already handles an arbitrary-shaped `RNative` value via
   `declareNative`, and `emitNativeValue`'s own bare-`RV` case (added
   Stage 3b of the dual-ABI effort, `doc/dual-abi.md`) already renders
   exactly this shape (a plain variable read in native context) --
   confirm both paths actually cover `declareNative`'s own dispatch for
   a bare `RV` value specifically (not just `emitNativeValue`'s) before
   assuming zero new Emit.idr work is needed here.
4. `body'` is `body` with every native-context reference to `argId`
   renamed to `shadowId` (`renameRCExp`-shaped, scoped to just this
   alt's own subtree) -- *not* every reference the way `Loop.idr`'s own
   rename does for a loop param (which redirects Boxed-context uses
   too, since a promoted loop param's *original* id becomes entirely
   dead): a con-alt field can still legitimately have its own
   *separate*, unrelated Boxed-context uses elsewhere in the same alt
   (e.g. `case acc of MkAcc x y => f x (show y)` -- `x`'s own native
   use and `y`'s own Boxed use coexist) that must keep reading `argId`
   itself, unrenamed.
5. `argId`'s own ownership bookkeeping (whatever `annotate` already
   decided, back when every native-context use it now no longer has
   still counted toward its own use-count) needs the same kind of
   surgical fixup `Loop.idr`'s own `stripOwnership` performs for a
   promoted loop param -- but *narrower*: only the specific `postDrop`
   entries/dup-decisions tied to the *renamed-away* uses are stale, not
   necessarily all of `argId`'s own bookkeeping (unlike a loop param,
   which becomes wholly dead once promoted, a con-alt field may still
   have real Boxed-context uses left, per point 4 -- `stripOwnership`
   itself, unmodified, assumes total removal, so this needs its own
   variant, not a direct reuse). Getting this exactly right is the
   crux of the whole layer -- this is precisely the kind of ownership
   surgery that produced the leak in the reverted first attempt, so it
   deserves the same `valgrind --leak-check=full` scrutiny against a
   dedicated test (a field read natively *and* in Boxed context within
   the same alt, and separately a field read natively more than once)
   before considering this done, not just a stdout diff.

This TODO entry, not `rc2/doc/`, is where this plan lives -- consistent
with the project's own convention that `rc2/doc/` is for finished
design/implementation, not an in-progress or twice-reopened one.

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
