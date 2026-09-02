# TODO

Known gaps and future work for rc2, tracked here rather than only in
scattered code comments. Nothing below is a known correctness bug in
what's implemented -- see `rc2/tests/refc-suite/README.md` for bugs that
were found and already fixed.

## Architecture: `RCLocal` can't hold another `RCLocal`

While designing `getField`/`setField` support (`rc2/doc/c-struct-support.md`),
considered making a struct field read a new `RCLocal` variant (e.g.
`RCStructField : RCLocal -> String -> String -> RCLocal`) instead of a
dedicated `RCExp` node -- it's a pure, ownership-neutral read, so it
would have been usable directly as an `ROp`/`RCon`/etc. operand, no
`RLet` needed just to name it first. Not pursued: `RCLocal`
(`RCLoc`/`RCNull`/`RCConst`/`RCEmptyCon`) is currently *atomic* --
every existing user (`freeLocalsR`/`countUsesR` in `RCExp.idr`,
`splitBorrows`/`boxedOperands` in `RC.idr`, and similar code across
`Reuse.idr`/`Sink.idr`/`Loop.idr`/`DualABI.idr`) relies on plain `==`
comparison and `fromList`/`filter` over `List RCLocal`, which only
works because no variant currently holds a nested `RCLocal` of its
own. Adding one that does (`RCStructField`'s own `structVar`) would
mean every one of those sites needs to recurse into the nested
`RCLocal` instead of just comparing values directly -- a broader,
riskier change than adding a new `RCExp` node (which only affects
`RCExp`-walking code, a smaller and more precedented surface, see
`Compiler.RC2.RC`'s own `ROp`-shaped precedent for `RStructGet`/
`RStructSet`). Went with the `RCExp` node instead. Worth reconsidering
if a future feature would benefit from embeddable-value locals badly
enough to justify auditing every `RCLocal` call site -- not currently
planned.

## Performance: native (unboxed) `Ptr`/`CFPtr` representation -- investigated, not pursued

Neither `getField`'s own result nor `setField`'s own `value`, nor a
struct pointer (`structVar`) itself, is ever native -- each pays for a
Boxed `IDRIS2RC2_Pointer` heap allocation just to carry one raw
pointer around. Investigated whether `Ptr`/`CFPtr` could join rc2's
existing native-representation machinery. Structurally blocked before
the semantics even come up: `Rep`'s `RNative`/`RInlineNative` are typed
over upstream's own `PrimType`, which has no pointer case at all, so
representing one at all needs a new `Rep` variant of rc2's own,
touching every module that pattern-matches on `Rep`. Semantically
murkier too: `CFGCPtr`'s own `onCollect` callback genuinely depends on
refcounting to fire, so it would need permanent exclusion (`CFPtr`
only); and even `CFPtr` alone would lose the weak reachability
tracking its current Boxed wrapper provides, with no borrow/lifetime
checker to make up for it once a future nested-struct-field-pointer
feature makes that tracking matter more. See
`rc2/doc/c-struct-support.md`'s own "Investigated: native (unboxed)
`Ptr`/`CFPtr` representation" section for the full writeup. Not
currently planned -- revisit only if profiling shows the allocation
cost actually matters, with a concrete plan for the `CFGCPtr` split
and the lifetime question.

## Performance: tail-position delegating calls stay boxed

Native type inference (`Compiler.RC2.Types`) only applies to values
that stay within a single function's ANF-normalized body -- every
function argument and return value used to always be boxed, meaning
native representations got boxed and reboxed at every call boundary.
Self-tail-calls sidestep this for loops specifically (`Compiler.RC2.Loop`,
see `rc2/doc/loop-conversion.md`), and the dual calling convention
(`Compiler.RC2.DualABI`, see `rc2/doc/dual-abi.md`) closes the gap for
essentially every *non-tail-position* call boundary too. What's left, deliberately:
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

## Dropped: skipping `idris2rc2_trampoline` for provably non-delegating functions

Investigated whether `Compiler.RC2.Emit`'s two call-emission sites that
unconditionally wrap a non-tail call in `idris2rc2_trampoline(...)`
(`emitRC`'s plain `RAppName` case, and `emitAppNameRepInto`'s `RBoxed`
branch) could skip that wrap when the callee is statically known to
never itself defer a tail call into a closure. The base property --
every genuine tail-position leaf of a function's body is a non-call
(`RV`/`ROp`/`RPrimVal`/`RCon`/`RErased`/`RCrash`/`RStructGet`/
`RStructSet`), never a saturated call (`RAppName`/`RAppNameRep`/
`RUnderApp`/`RApp`) -- is decidable per-function with no whole-program
fixed point, the same shape `Compiler.RC2.DualABI`'s
`paramEligibility`/`returnEligibility` already use. The natural home
for the decision is a new field directly on `MkRCFun` itself (mirroring
`ROp`'s own `postDrop`), not on every call site referencing it --
`RAppName`/`RAppNameRep` would need no changes at all, and
`Compiler.RC2.Emit` could derive a lookup set once from `defs`, the
same way it already derives `StructDefs`.

Dropped before implementation once its actual payoff was traced
through: it provides **zero benefit for the flagship `fib`-shaped
case** -- `Compiler.RC2.DualABI`'s own Stage 3b/4 already renders a
native (`RNative`/`RInlineNative`) worker return without ever calling
`idris2rc2_trampoline` at all (a native value can never be a closure),
so this would-be optimisation only reaches the disjoint, narrower set
of Boxed-returning, non-delegating functions (e.g. ones returning
`List`/`Maybe`/a user ADT) plus `%foreign` calls (always eligible,
unconditionally). Extending it to also cover *delegating* functions
(`g x = h x`, promoting `g` once `h` is known trampoline-free) was
considered and found unsound as a simple flag-propagation: `g`'s own
tail call to `h` is still unconditionally deferred into a closure by
`tryBuildClosureInto` regardless of `h`'s own properties, so skipping
the caller's trampoline would hand back an undispatched closure as if
it were the final value. Making it sound would require also rewriting
`g`'s own tail-position emission to call `h` directly (no closure
deferral) -- safe only if the delegation subgraph reachable from `g`'s
tail position is acyclic, which in turn depends on trusting that
`Compiler.RC2.Loop`/`Compiler.RC2.MutualLoop` have already eliminated
every tail-recursive cycle before this pass would run (an unverified
completeness claim), or building explicit cycle detection (SCC) as a
safety net. This is exactly the same "pure tail-call delegation"
territory the "tail-position delegating calls stay boxed" entry above
already flags as deliberately unsolved, wearing a different name.
Given the real verification burden, the reopened stack-safety
territory `doc/dual-abi.md`'s own Stage 4 permanently excluded, and no
profiling evidence the narrow (non-propagated) win is worth pursuing
on its own, not implemented; revisit only if profiling shows Boxed-
returning non-delegating call sites are a real hot path.

## Performance: loop accumulator threaded only through helper calls stays boxed

A loop-carried accumulator only skips boxing across iterations when
it's read directly as an `ROp`/`RCmpCase` operand inside the loop body
itself (`Compiler.RC2.Loop`'s own native-shadow promotion, see
`rc2/doc/loop-conversion.md`). When it's instead only ever passed *as
a call argument* to a helper function (e.g. a `step`-shaped function
called from within the loop), it stays boxed across iterations:
`nativeArgTypes` has no case recognizing "used as an argument at a
position a callee's own native-signature worker accepts natively" as
a native-context use. Unaddressed, would need its own follow-on change
(teach `nativeArgTypes` about `RAppNameRep`/`callRep` argument
positions); not currently planned. The related but distinct gap for an
ordinary case-alternative's own destructured field (not loop-carried)
was addressed separately (`Compiler.RC2.ConAltNative`, see
`rc2/doc/con-alt-native.md`).

## Performance: `Loop.idr`'s own loop-carried (non-invariant) native shadow still reboxes fresh on a Boxed-context read

`EmitUtil.idr`'s `rcVarToBoxedC` (its own doc comment states this
explicitly) boxes a `Native`/`RInlineNative` local by always calling
`nativeMk` (`idris2rc2_mkInt64`/etc.) -- a fresh allocation, never a
`dup` of whatever Boxed object the value was originally unboxed from.
Fixed for `Compiler.RC2.ConAltNative`'s own destructured-field caching
(see `rc2/doc/con-alt-native.md`'s own "Reusing the original Boxed
field for surviving Boxed-context reads" section) and for
`Compiler.RC2.Loop`'s own loop-*invariant* parameter hoisting (see
`rc2/doc/loop-conversion.md`'s own "Reusing the original Boxed value
for a surviving Boxed-context read" section): a Boxed-context read of
a promoted field, or of an invariant loop parameter's own native
shadow, now keeps sharing the original value's own identity via an
ordinary `dup`, instead of paying for a fresh reallocation every time.
The invariant-parameter fix deliberately never *moves* (unlike
`ConAltNative`'s own "first occurrence moves, later ones dup" rule) --
a surviving Boxed-context read can sit on the loop's own *continue*
path, re-executed once per iteration, so every occurrence is `dup`'d
unconditionally and the parameter's own single release is deferred
until the whole loop has finished evaluating, once.

**Still not fixed for `Compiler.RC2.Loop`'s own genuinely loop-*carried*
(non-invariant) native-shadow promotion** -- structurally harder than
either fix above: a loop-carried shadow's own value is reassigned every
iteration (`continue loop [...]`), so unlike a destructured field's or
an invariant parameter's own one-time, unchanging read, "the original
Boxed object this shadow came from" isn't a single, fixed thing --
after the first iteration, a loop param's own current native value
typically comes from an arithmetic result with no Boxed original to
`dup` at all, not from re-reading the same Boxed local. Not attempted;
not currently planned.

`Loop.idr`'s `nativeArgTypes`/`nativeArgType` (the eligibility check
that gates promotion for `Loop.idr`/`ConAltNative.idr` alike) still
doesn't weigh reboxing cost either way: it only asks whether a
parameter/field is ever read in a native context at a consistent type,
never how many *Boxed*-context reads there are. This no longer risks a
net slowdown for `ConAltNative` or for an invariant loop parameter (a
Boxed-context read is cheap again, an ordinary `dup`); for a genuinely
loop-carried parameter (still unfixed, above), a variable read natively
once but read Boxed many times across iterations could still plausibly
get slower under promotion, not faster. `idris2rc2_mkInt64`/`mkBits64`
do have a 0-99 small-value cache (`memory.c`), so the real cost only
bites for out-of-range integers and for types with no such cache
(`Double`, wider `Int`/`Bits` values outside 0-99) -- unmeasured how
often that actually happens in practice.

## Dropped: loop-invariant constructor-field hoisting

Two entries, investigated and dropped together -- "loop-invariant
single-branch case hoisting" and `ConAltNative`'s once-planned
extension "across loop/dual-ABI boundaries" turned out to be the same
underlying gap wearing two different names. See
`rc2/doc/case-hoisting-scope.md` for the full writeup (why it looked
worth doing, what the investigation found, and why neither design
considered was pursued).

## Dropped: closure generation for statically-known higher-order function arguments

Investigated why `map double [1,2,3,4,5]`-shaped code pays for a fresh
closure allocation on every call even though `double` is a statically
known top-level function: `--directive dumplifted` (upstream's own
debug flag) confirms Idris2's own frontend never passes a bare
top-level reference at all -- `Compiler.LambdaLift`'s `liftExp (CRef fc
n) = LAppName fc lazy n []` means any function value is always an
eta-wrapped, lambda-lifted helper (`Main.{main:2} = [][{eta:0}]:
Main.double(!{eta:0})`), reaching the call site as an `LUnderApp` with
zero arguments filled in. `Prelude.Types.List.mapAppend` itself reads
that closure exactly once per element via `LApp` (`!{arg:3} @
(!{e:1})`), lowering to `Compiler.RC2.Emit`'s `apply`/
`idris2rc2_tailcallApplyClosure` -- a tag check plus indirect dispatch,
on top of the allocation.

Two fix directions considered, both dropped:

1. **Cache/immortalise the closure** (mint it once, reuse the same
   `IDRIS2RC2_Value*` at every call site, the same
   `IDRIS2RC2_REFCOUNT_MAX` trick the 0-99 small-int cache already
   uses). Blocked by a genuine, previously-latent runtime bug this
   investigation surfaced: `support/rc2/runtime.c`'s
   `idris2rc2_tailcallApplyClosure`'s own non-unique branch
   unconditionally does `--c->header.refCount` with no
   `REFCOUNT_MAX`-check guard the way `idris2rc2_drop` itself has --
   `idris2rc2_isUnique` (`refCount == 1`) correctly steers an immortal
   closure away from the *in-place*-mutation branch (`c->args[filled] =
   arg`), but the non-unique branch's own unconditional decrement would
   still corrupt the immortal marker down to a real, finite count the
   moment such a closure were ever `apply`'d. Fixing the runtime side
   first is a precondition this document doesn't take further -- not
   attempted.
2. **Specialise the callee per statically-known argument** (clone
   `mapAppend` once per distinct function it's ever called with,
   replacing the cloned copy's own `apply` with a direct call --
   designed down to reusing `Compiler.RC2.Inline`'s own `Lifted`
   Weaken/Substitutable plumbing, detecting a parameter read only via
   `LApp` and invariant across the callee's own self-recursive calls
   the same way `Compiler.RC2.Loop`'s `invariantLoopParamIds` detects
   an invariant loop parameter). Note this is *not* the same thing as
   inlining `mapAppend` itself: `mapAppend`'s own `Lifted` form is a
   genuine self-recursive call (`Compiler.RC2.Loop`'s loop conversion
   hasn't run yet at this pipeline stage), so it already fails
   `Compiler.RC2.Inline`'s own `isCallFree` criterion and was never a
   candidate for straight inlining regardless -- specialisation instead
   means minting one *new*, still-self-recursive definition per
   distinct callee/argument pair. **Dropped once the cost of that "one
   new definition per distinct argument" scaling became clear**: any
   generically-written higher-order helper called with many different
   functions across a program (not a rare shape -- `map`/`filter`/
   `foldl` equivalents are used pervasively) would each mint their own
   near-duplicate specialised copy, trading a per-call allocation for a
   permanent, unbounded growth in generated-code size -- a worse
   trade for anything but a narrow, deliberately-curated allowlist of
   hot call sites, which this document's own design never scoped down
   to. Not implemented; not currently planned.

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

## Performance: constant-constructor folding doesn't cross a CAF boundary or a case scrutinee

`Compiler.RC2.ConstFold`'s `RCConstCon` folding (see
`rc2/doc/const-con-fold.md`) only folds literal constructor nesting
*within one definition's own body* -- deliberately MVP-scoped, two
gaps left for later:

- A `RAppName` referencing another top-level CAF is never treated as
  constant, even when that CAF's own body folds entirely. Folding
  through would need whole-program dependency resolution (which CAF
  folds first if two reference each other) this pass doesn't attempt.
- `RConCase`/`RConstCase`'s own scrutinee (`sc`) is never resolved
  against a folded `RCConstCon`, so a `case` over a
  provably-constant value still compiles to a real runtime dispatch
  instead of folding away. `Compiler.RC2.Reuse` and `Emit.idr`'s own
  case-lowering both currently assume a scrutinee is a real heap
  `RCLoc` -- both would need auditing before this could be lifted.

Not pursued further this round -- see `const-con-fold.md`'s own
"Scope / limitations" and "Verification methodology" sections for the
reasoning and what to check before extending either.

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

## Dropped: unwrapping `Just x` to a bare `x` (nullable-pointer `Maybe`)

Investigated turning `Maybe`-shaped types' non-nullary constructor into
a zero-allocation passthrough, matching `Nothing`'s existing `NULL`
representation -- i.e. `Just x` would just *be* `x` (plus whatever
`dup` ordinary variable sharing already needs), never a real
`idris2rc2_newConstructor` heap allocation. Motivated by noticing that
`Nothing` already compiles to a bare C `NULL`
(`support/rc2/datatypes.h`'s "Nil/Nothing/Z/MkUnit" comment) while
`Just x` still allocates.

The mechanics turned out easy: `ConInfo`'s `JUST` (`idris2-src/src/Core/
CompileExpr.idr`) is a shape-based tag upstream Idris2 itself assigns
to *any* option-shaped type's non-nullary constructor, not just
`Prelude.Maybe`'s -- one `ci == JUST` check is enough, no need to
inspect the whole datatype. `Compiler.RC2.EmitUtil`'s
`conAltCondExpr` already discriminates a `JUST` alt with plain `NULL !=
sc'`, no tag comparison at all -- exactly the test this scheme needs
and already in place. The only genuinely new code would have been:
`Compiler.RC2.RC`'s `bindOne`/`normalize` skip constructing an `RCon`
for a `ci == JUST` application and bind its single argument directly
instead (so no `RCon fc n JUST ...` node is ever produced), a matching
case in `Emit.idr`'s `emitConAltBody` (alias the scrutinee itself
instead of reading `args[0]`), and adding `JUST` to `Reuse.idr`'s
`resolveAlt` `erased` set (so the reuse pass doesn't try to treat a
no-longer-boxed `JUST` scrutinee as reusable heap storage). No new
`RCExp`/`RCLocal` node needed, no new ownership rules -- confirmed by
reading the full pipeline before writing any code.

**Dropped once a concrete soundness counterexample was found**: the
scheme collapses `Just x` and `Nothing` into the same `NULL`
representation whenever `x`'s own value can itself be `NULL` --
which is exactly the case for `Just []` (`x : List a`), `Just ()`,
`Just Nothing` (nested `Maybe`), and any user type sharing the
NIL/NOTHING/ZERO/UNIT shape. Confirmed by building a real program and
reading the generated C: today, `Just []` correctly compiles to a
distinct (`ConstFold`-staged, immortal) non-`NULL` object --
`return ((IDRIS2RC2_Value*)&constcon_12);` with `constcon_12.args[0] =
NULL` -- while `Nothing` compiles to bare `NULL`; unwrapping `Just`
would make both `NULL`, indistinguishable at runtime. `Compiler.RC2`
operates on already-erased `Lifted` IR at this stage, with no general
way to prove "this `Just`'s payload type can never itself be
`NULL`-representable" from local syntax alone -- this isn't a
where-to-implement-it problem (IR vs. `Emit`, hand-written C swap,
etc. all hit the identical soundness gap), only a
provably-safe-payload-type problem. Not implemented, not currently
planned; would need either a narrow, conservatively-safe subset (e.g.
only payloads whose shape is syntactically visible and provably
non-`NULL` at the exact `Just` call site) or recovering real type
information at this IR stage (`Compiler.RC2.Types`'s native type
inference does something in this spirit for a much narrower purpose --
worth a look if this is ever revisited) to be viable.

Not to be confused with `libs/rc2base/support/c/concurrency_util.c`'s
`Channel` primitives (`rc2/doc/concurrency.md`'s "Design: Channel"),
which *do* build `Just` values directly from C -- that's a different,
sound thing: always constructing a real `Constructor` for
`Prelude.Maybe` specifically (a fixed library type whose `Just` tag is
known and stable), never eliding one for an arbitrary payload type.

## Test coverage gaps

One of upstream Idris2's own `tests/refc/*` regression tests is
deliberately not ported (see `rc2/tests/refc-suite/README.md` for the
full reasoning; `ccompilerArgs`, the other test this section used to
list as unported, is now ported -- same README, "Ported (20)"):

- **`callingConvention`**: upstream's version `awk`-inspects the shape
  of RefC's own generated C, which isn't meaningful for rc2's
  structurally different codegen. No rc2-specific replacement exists
  yet that would pin down the *current* calling convention's C shape
  (now partly dual-ABI'd for eligible functions, see
  `rc2/doc/dual-abi.md`) as a regression guard -- worth writing from
  scratch.

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

## Semantics: `Lazy`/`Force` defers evaluation but doesn't memoize (except one Chez-only special case)

Confirmed by direct experiment (a `Lazy Int` built via `delay
(unsafePerformIO (do putStrLn "computing!"; pure 42))`, forced twice
through a shared function parameter) that rc2's `Lazy`/`delay`/`force`
provides deferred-evaluation *timing* only, not call-by-need *sharing*:
forcing the same delayed value twice re-runs the underlying computation
from scratch both times (`computing!` printed twice), rather than
computing once and reusing the cached result the way Haskell's lazy
thunks do. The deferred-timing half still works correctly (a separate
experiment confirms the sequenced side effect inside `delay` doesn't
run until the first `force`, not at the `delay` call site itself).

Root cause, traced to `idris2-src/src/Compiler/LambdaLift.idr`: both
`rc2/src/Compiler/RC2/RC2.idr` and upstream `Compiler.RefC.RefC` call
`getCompileData` with `doLazyAnnots = False` (`RC2.idr`'s own call site,
`RefC.idr:1005`) -- **not rc2-specific**, the identical choice upstream
RefC itself makes. Under that flag, `LambdaLift.idr`'s `liftExp`
compiles `Delay e` to a plain zero-argument closure (`CLam (MN "act" 0)
e`) and `Force t` to a plain call on it (`CApp t [CErased]`) -- no
memo cell, no "already forced?" check, nothing beyond an ordinary
closure and an ordinary application. Confirmed directly in rc2's own
generated C too: a `force`d-twice value compiles to two independent
`idris2rc2_applyClosure(var_0, NULL)` calls with nothing cached between
them.

**Not actually a Chez-vs-RefC gap in general**, despite first looking
like one: a naive `idris2 --cg chez` run of the same experiment prints
`computing!` only *once*, but that turned out to be a narrow special
case, not `Force`/`Delay` sharing in general -- confirmed by re-running
the same experiment with the `Lazy` value built from a runtime
parameter instead of a closed literal (so it can't be floated to a
top-level binding), which prints `computing!` *twice* under `idris2
--cg chez` too, identical to rc2/RefC. The one-time-only result only
happens for a top-level definition (or a `let`-binding the compiler
floats to one, which happens whenever nothing in it depends on a
function argument) whose entire body is literally `Delay e`:
`Compiler.Scheme.Common.idr`'s `schDef` has a dedicated case for
exactly that shape (`MkNmFun [] (NmDelay _ _ exp)`, its own comment:
"Special version for memoized toplevel lazy definitions"), emitting
Scheme's own native `(define name (delay expr))` instead of going
through the generic `LazyExprProc`-driven `(lambda () expr)`/`(expr)`
pair every other `Delay`/`Force` site uses (`defaultLaziness`, same
file) -- and that native `delay` only ends up evaluated once *because*
Chez's own top-level `define`s are genuinely shared CAFs, unlike rc2/
RefC's (a top-level 0-argument definition is a plain function re-run on
every reference on this backend, no memoization at all -- confirmed
separately in this project's own investigation of `System.Random.
Xoroshiro128PlusPlus`'s global-state design). So the real picture: a
`Lazy` value that's a closed top-level constant is memoized on Chez
(CAF-sharing + the native-`delay` special case working together) but
never on rc2/RefC (no CAF-sharing at all); a `Lazy` value built at
runtime from live data -- the ordinary/common case, e.g. a `Lazy`-typed
function argument -- is *not* memoized on **any** of the three checked
here (Chez included).

Also investigated in passing: `LambdaLift.idr`'s other branch,
`doLazyAnnots = True`, is not a path to memoization either. Under it,
`Delay e`/`Force t` are erased entirely rather than becoming a closure
-- `e`/`t` gets lifted in place, evaluated exactly where it's written,
with only a `lazy : Maybe LazyReason` marker left on whatever call/op
node it lifts to (`Compiler.RC2.RCExp`'s own `lazy` fields on
`RAppName`/`RApp`/`ROp`/`RExtPrim` exist for this, currently always
`Nothing` since rc2 never sets `doLazyAnnots = True`). Flipping it
would *remove* rc2's current (working) deferred-timing guarantee
entirely -- `Delay`'s side effect would fire immediately, not at first
`Force` -- and buys no memoization on its own; the `lazy` marker itself
drives no runtime behavior anywhere in `Compiler.RC2.Emit` today, and
would need real new codegen (something like a C-side version of Chez's
own memoizing-thunk helper, `blodwen-lazy` in
`idris2-src/support/chez/support.ss`: a heap-allocated closure plus an
"already forced?" flag and a cached result slot) to turn that marker
into anything. No backend currently ships with `doLazyAnnots = True`
(checked Chez/Racket/Gambit/RefC/the VM interpreter -- all pass
`False`); it reads as unused groundwork for some future ANF/VM-style
backend, not a switch rc2 could usefully flip today.

Not a bug to fix -- this is RefC-family behavior rc2 deliberately
inherits unchanged, and every use of `Lazy`/`force` in this codebase's
own source (this survey's own search) happens to be single-use, so it
hasn't caused an observed problem. Noted here because it's a real,
easy-to-miss semantic gap from Haskell-style (and, for the narrow
top-level-constant case, Chez-style) lazy evaluation: code written
assuming a `Lazy` value (particularly a `Lazy`-typed function argument,
forced more than once inside the function) is evaluated at most once
will silently get O(n) re-execution instead on rc2 (and on real `idris2
--cg refc`) -- functionally correct for a referentially transparent
computation, but wrong for anything relying on the *once-only*
guarantee (a genuine side effect, or the performance assumption that
memoizing an expensive pure computation behind `Lazy` actually
memoizes it here). Revisit only if a concrete program actually needs
shared-thunk semantics badly enough to justify a real memoizing-thunk
implementation (a mutable "forced?" cell wrapping the closure, roughly
the same shape `IDRIS2RC2_IORef` already uses) -- non-trivial given it
would need to interact correctly with this project's own reference-
counting/reuse machinery, and no concrete need has surfaced yet.

**Follow-up investigated, not implemented**: could the narrow, common
"top-level constant defined as exactly `delay expr`" case (the one
Chez memoizes via its own special case, see above) be given the same
treatment on rc2, using the `lazy : Maybe LazyReason` markers
`doLazyAnnots = True` would populate? Worth checking since it looked,
at first, like a small, targeted win rather than a general memoizing-
thunk implementation. Four things came out of chasing it:

1. **Flipping `doLazyAnnots` globally is not safe.**
   `Prelude.Basics`'s `(&&)`/`(||)` are implemented over `Lazy Bool`
   for short-circuiting (`(&&) True x = x; (&&) False x = False`), and
   general corecursive structures (`Stream`, `Colist`, ...) depend on
   `Delay` never running early. Turning `doLazyAnnots` on for the whole
   program erases *every* `Delay` into immediate evaluation (this
   entry's own "Semantics" discussion above), which would break both
   outright. Any safe version of this idea has to detect and special-
   case only the exact `MkNmFun [] (NmDelay _ _ exp)` shape -- matching
   `Compiler.Scheme.Common.idr`'s own `schDef` case for it -- while
   leaving `doLazyAnnots = False` (and hence every other `Delay`/`Force`
   site's existing, correct, deferred-but-non-memoizing closure
   compilation) untouched.

2. **That detection is free, as it turns out.** Traced
   `idris2-src/src/Compiler/Common.idr`'s `getCompileDataWith`: the
   `namedDefs <- traverse getNamedDef cseDefs` line runs unconditionally,
   regardless of the requested `UsePhase` -- so rc2's own existing single
   `getCompileData False Lifted tm` call already produces a fully
   populated `cdata.namedDefs : List (Name, FC, NamedDef)`, with the
   exact `NamedDef`/`NamedCExp` shape (`MkNmFun [] (NmDelay _ _ exp)`)
   Chez's own `schDef` pattern-matches on. No second compilation pass
   needed to build the "these top-level names are pure `delay expr`
   constants" set.

3. **But changing just the 0-argument CAF's own codegen turns out not to
   be enough.** Under `doLazyAnnots = False`, `Delay e` compiles to a
   closure (`CLam (MN "act" 0) (weaken e)`), so a CAF like `sideEffect :
   Lazy Int; sideEffect = delay e` compiles to a genuine 0-argument C
   function that *builds and returns a closure object*
   (`Main_sideEffect(void) { return
   idris2rc2_mkClosure(Main_sideEffect_1, ...); }` -- confirmed against
   real generated C, not assumed; also confirmed rc2's own pipeline
   never pads a 0-argument top-level definition with a dummy parameter
   for any reason -- the only "dummy argument" concept anywhere in
   `Compiler.RC2` is `DualABI.idr`'s `CFWorld` token, which belongs to
   `IO a`'s own FFI representation, unrelated to a plain `Lazy a` CAF).
   `Force t`'s own compiled form is unconditionally `CApp fc tm
   [CErased fc]` -- "apply whatever `tm` evaluates to as a closure" --
   so memoizing only `Main_sideEffect` itself (making it return the
   *same* closure object every call, fixable with an atomic
   compare-and-swap-guarded static cache) is not sufficient on its own:
   the closure *object itself* (its body function, e.g.
   `Main_sideEffect_1`, the thing `idris2rc2_applyClosure` actually
   invokes) still has no "already forced, here's the cached result"
   state, so a second `force` on the same (now correctly shared) closure
   would still recompute. A real fix needs *both* the CAF-sharing half
   above *and* a new memoizing closure representation (a "forced?" flag
   plus a cached-value slot, checked by `idris2rc2_applyClosure` or
   equivalent) -- touching `datatypes.h`'s own closure layout, not just
   `Compiler.RC2.Emit`'s codegen for 0-argument top-level definitions.
   Meaningfully bigger than the initially-hoped-for "just change how a
   0-arg CAF compiles."

4. Were this pursued, the natural choice for guarding the memoizing
   closure's first-computation race (rc2 has real OS threads,
   `doc/concurrency.md`) is an atomic compare-and-swap/double-checked
   pattern rather than a `Mutex` -- lock-free, and acceptable since the
   worst case under a genuine race is redundant (not incorrect)
   recomputation for a referentially transparent value, the same
   tradeoff this whole entry already accepts for the *unmemoized*
   general case.

5. Point 3's conclusion (a new representation is unavoidable) isn't
   speculation -- upstream itself already ships exactly this tradeoff
   for the *general* (non-CAF) case, opt-in only, on the Scheme
   backends: `--directive lazy=weakMemo` / `%cg chez lazy=weakMemo`
   (`Compiler.Common.getWeakMemoLazy`, read only by
   `Compiler.Scheme.{Chez,Racket,Gambit}`, never by RefC or rc2) swaps
   every generic `Delay`/`Force` site from the default `(lambda ()
   expr)` / `(expr)` pair (`Compiler.Scheme.Common.defaultLaziness` --
   the same non-memoizing shape rc2/RefC always use) to
   `weakMemoLaziness`: `(blodwen-delay-lazy (lambda () expr))` /
   `(blodwen-force-lazy expr)`. Confirmed by compiling a `Lazy` value
   built from runtime data (can't be floated to a CAF) with and without
   the directive: `computing!` prints twice by default, once with
   `lazy=weakMemo` on. `idris2-src/support/chez/support.ss`'s own
   implementation:
   ```scheme
   (define (blodwen-delay-lazy f) (weak-cons #!bwp f))
   (define (blodwen-force-lazy e)
     (let ((exval (car e)))
       (if (bwp-object? exval)
           (let ((val ((cdr e)))) (set-car! e val) val)
           exval)))
   ```
   -- a genuinely new representation (a `weak-cons` pair: `car` starts
   as the not-yet-computed sentinel `#!bwp` and is overwritten with the
   result on first force, `cdr` holds the thunk), not a flag on the
   existing closure shape. And it's deliberately *weak*: `car`'s cached
   result can be GC'd if nothing else references it, silently forcing a
   recomputation on the next `force` -- "memoized as long as memory
   pressure allows", not the strict once-only guarantee the top-level-
   CAF special case's real `(delay ...)` gives via strong references.
   Confirms this dial exists precisely because unconditional *strong*
   memoization for every `Delay`/`Force` has a real memory cost upstream
   itself isn't willing to pay by default (matters for long corecursive
   chains, `Stream`/`Colist`, where pinning every historical thunk's
   result forever would defeat the point of streaming in the first
   place) -- a consideration any real rc2 implementation of point 3
   would inherit too.

Not implemented -- point 3 changes this from a small, contained fix
into a new runtime representation plus matching `Compiler.RC2.Emit`/
`idris2rc2_applyClosure` work, and no concrete program has needed it
yet. Revisit starting from this writeup (particularly points 3 and 5)
if one does.

## `Integer` (`CFInteger`) `%foreign` codegen: argument position done, return position still unsupported

Found while investigating whether `idris2-json` (stefan-hoeck's JSON
marshalling library, via `pack`'s collection) could build against rc2.
Its transitive dependency `idris2-array`'s own `Data.Buffer.Core`
declares several low-level buffer primitives (`prim__newBuf`,
`prim__getByte`, `prim__setByte`, `prim__getString`, `prim__fromString`,
`prim__copy`) typed over `Integer` (arbitrary-precision) offsets/
lengths, rather than `Int` (fixed-width) like upstream `Data.Buffer`'s
own equivalents use. Confirmed directly with a minimal repro
(`%foreign "C:atoi,libc 6" prim__atoi : String -> Integer`, no other
code) that any `%foreign`-declared function with an `Integer` argument
or return type used to crash rc2's own codegen outright:
`ERROR: INTERNAL ERROR: Unknown FFI type in rc2 backend: Integer`.
**Not rc2-specific**: confirmed the identical crash against upstream
`idris2 --cg refc` with the same repro -- RefC's own `RefC.idr` has the
exact same gap (unaffected by anything below, which is rc2-only).

Argument position now implemented: `IDRIS2RC2_Integer.v` is a GMP
`mpz_t`, itself defined by GMP as a one-element array type, which
already decays to the `mpz_t`/`mpz_ptr` a real GMP-based C function
expects when read directly -- `Compiler.RC2.EmitUtil`'s `extractValue`
hands it over with no copy, no truncation, no boxing/unboxing shim
needed (`rc2/tests/Test54FFIInteger.idr` confirms round-tripping a
30-digit value, well outside `Int`'s 64-bit range, through a real
`mpz_get_str` on the C side). The one caveat: this hands the callee the
*actual* mutable GMP state backing the Idris value, not a defensive
copy -- safe to read, never to mutate in place (Idris's own semantics
promise `Integer` is immutable and the value may be aliased/refcounted
elsewhere), documented directly on `extractValue`'s own `CFInteger`
case.

Return position deliberately still rejected (`packCFType`'s own
`CFInteger` case throws a dedicated "only supported as an argument, not
a return type" crash, replacing the old generic "Unknown FFI type"
one): GMP's own `mpz_t` has no valid "return by value" C shape (a real
GMP function needing to hand back an arbitrary-precision result takes
an output `mpz_t` parameter instead, returning `void` -- the idiom
`mpz_add`/`mpz_set`/etc. all follow). Next step agreed: support this by
having a `%foreign` declaration whose Idris return type is `Integer`
compile to a C call with an *extra*, implicit trailing `mpz_t`
argument -- a freshly allocated (but not yet initialized-to-any-value)
`IDRIS2RC2_Integer`'s own embedded `mpz_t`, matching every other GMP
API's own out-parameter convention -- rather than one of the
previously-considered alternatives (truncating to a fixed width, or a
string-based round trip). Not yet implemented as of this entry.

## Pinned reference `idris2 --cg refc` 0.8.0 rejects `Int32` in `%foreign` position

Found while writing `rc2/tests/Test27FFIDualABI.idr` (the dual-ABI FFI
worker's own smoke test, see `rc2/doc/dual-abi.md`'s "Stage 3c"): a
`%foreign`-declared function with an `Int32` argument or return type
compiles fine under `idris2-rc2`, but `verify.sh --regen-expected`'s
own cross-check against the pinned reference `idris2 --cg refc` (this
project's own installed 0.8.0) fails with `ERROR: INTERNAL ERROR:
Unknonw FFI type in C backend: Int_32` [sic, upstream's own typo].
Confirmed with a minimal repro outside the test suite. **Not
rc2-specific, and not what this project's own `Compiler/RC2/EmitUtil.idr`
does** -- rc2's own `cTypeOfCFType`/`extractValue`/`packCFType` already
handle `CFInt32` correctly (`int32_t`, same as the `idris2-src` clone's
own `Compiler/RefC/RefC.idr`); this is purely a gap in the specific
pinned 0.8.0 *binary* used for cross-checking, apparently predating
`Int32` FFI support landing upstream. `Int8`/`Int16`/`Int64`/
`Bits8`/`Bits16`/`Bits64`/`Double` all confirmed fine against the same
binary. Worked around in `Test27FFIDualABI.idr` by using `Bits64`
instead of `Int32` for that test's "all-native-arguments" coverage --
not a real gap in this project's own Int32 support, just untestable
against this one pinned reference. Revisit (i.e. add an `Int32` case
back to that test) if the pinned reference `idris2` version is ever
bumped past whatever release added `Int32` FFI support.

## Pinned reference `idris2 --cg refc` 0.8.0 misspells `negate` for fixed-width/`Double` types

Found while writing the `Int64`/`Bits64`/`Double` extension of `ROp`
reuse-in-place (now merged into `rc2/tests/Test49IntegerOpReuse.idr`;
see `rc2/doc/rop-reuse.md`): the pinned reference `idris2 --cg refc`
0.8.0's own installed runtime support header (`mathFunctions.h`, at
`/nix/store/.../libidris2_support-0.8.0/share/refc/mathFunctions.h`)
defines `idris2_nagate_Int8`/`idris2_nagate_Int16`/
`idris2_nagate_Int32`/`idris2_nagate_Int64`/`idris2_nagate_Double` --
misspelled ("nagate", not "negate") -- as macros, while that same
pinned reference's own codegen (confirmed by inspecting a `_refc.c`
compile error) emits calls to the correctly-spelled
`idris2_negate_<...>`. Any Idris2 program using `negate` on any
fixed-width int or `Double` type therefore fails to *link* (technically
a C compile error: `implicit declaration of function
'idris2_negate_Double'`) against this one pinned binary. Confirmed via
a real compile error, not just by reading the header. `Integer`'s own
`idris2_negate_Integer` is a real, correctly-spelled function (not a
macro) and is unaffected. **Not rc2-specific** -- confirmed
`rc2/support/rc2/numeric.h`'s own `idris2rc2_negate_Int64`/
`negate_Double` are spelled correctly and completely unaffected; this
is purely a defect in the one pinned reference *binary* used for
cross-checking, exactly the same class of gap as the "Pinned reference
`idris2 --cg refc` 0.8.0 rejects `Int32` in `%foreign` position" entry
above. Worked around in `Test49IntegerOpReuse.idr`'s fixed-width extension
coverage by not exercising `negate` there at all (a comment in the test
file explains why, and points out that same file's original
`Integer`-typed `negate` usage already covers the *general*
reuse-consuming-`Neg` pattern, since `Integer`'s negate is unaffected by
this reference bug). Revisit (i.e. add `negate` coverage back to that
extension) if the pinned reference `idris2` version is ever bumped past
whatever release fixes this typo.

## Upstream stdlib `%foreign` declarations with no C/RefC backend at all

Surveyed every `%foreign` declaration in `idris2-src/libs` (206 across
27 files, `base`/`prelude`/`contrib`/`network`) for ones carrying no
`"C:..."`/`"RefC:..."` alternative whatsoever (including the indirect
forms -- `supportC`/`libc`/`libterm`/`signalFFI`-style local helper
functions that stitch a `"C:..."` string together at compile time
rather than writing the tag literally; these had to be read past to
avoid false positives). Anything without a C-tagged alternative is a
function the *pinned reference* `idris2 --cg refc` itself cannot call
at all -- not an rc2-specific gap. Four such spots, all upstream; three
have since been patched independently by `libs/rc2base` (see the
"Partial exception"/"Also patched" paragraphs below), the fourth
(`System.Future`) has not:

- **`Data.Buffer`**: `setInt8`/`getInt8`/`getInt16`/`setInt64`/
  `getInt64` each carry only a `"scheme:..."` tag. Notably asymmetric
  with their own siblings in the same file -- `setInt16`/`getInt32`/
  `setInt32` do carry a `"RefC:..."` tag (`setBufferInt16LE`/
  `getBufferInt32LE`/`setBufferInt32LE`), so this looks like an
  upstream oversight rather than a deliberate scheme-only design.
  `rc2/support/rc2/buffer.h` already had C-side macros that could back
  every one of these (`setBufferUInt8`/`getBufferUIntLE`/
  `setBufferInt64LE`/`getBufferInt64LE`, etc.) -- the only missing
  piece was the upstream `%foreign` tag itself; now patched, see
  "Also patched" below.
- **`Data.Double`**: `unitRoundoff`/`epsilon`/`nan`/`inf` carry only
  `"scheme:..."`/`"node:..."` tags -- no C alternative at all.
- **`System.Random`** (contrib): `prim__randomBits32`/
  `prim__randomDouble`/`prim__srand` (backing the whole module,
  including its `Random Int32`/`Random Double` instances and
  `rndFin`/`rndSelect`/`rndSelect'`) carry only `"scheme:..."`/
  `"javascript:..."` tags. The entire module is unusable on any C
  backend, refc included.
- **`System.Future`** (contrib): `prim__makeFuture`/
  `prim__awaitFuture` (backing `fork`/`await` and the `Functor`/
  `Applicative`/`Monad Future` instances) carry only a `"scheme:..."`
  tag. Entire module unusable on any C backend, refc included. Not to
  be confused with rc2's own, unrelated joinable fork (`forkJoin`/
  `join`/`JoinHandle`, `rc2/doc/concurrency.md`'s "Design: joinable
  fork") -- that's an rc2-specific addition with no upstream
  `System.Future` involvement at all, built to cover a gap upstream's
  own `threadWait` (see next paragraph) leaves open on every C backend.

One more single-function case surfaced by the same survey,
`prim__threadWait` (`libs/prelude/Prelude/IO.idr`) -- also
`"scheme:..."`-only, unlike its own sibling `prim__fork` (which does
carry `"C:refc_fork"`) -- is *not* a fresh finding: it's the exact gap
`rc2/doc/concurrency.md`'s "Design: joinable fork" section and
`rc2/support/rc2/ioprims.c`'s own comments already document at length
(upstream's `fork` can spawn a thread from C, but nothing about
`ThreadID`'s representation lets any C backend ever implement
`threadWait` to join it back) -- included here only so this survey is a
complete index of the same class of gap, not as new information.

`System.Future` remains genuinely un-investigated: it hasn't surfaced
as a real blocker for any program built against rc2 so far (unlike
`System.Concurrency`, which had actual demand behind it, or
`Data.Buffer`/`Data.Double`/`System.Random`, patched below once looked
at). Revisit with a `%foreign_impl` patch or a from-scratch
replacement, `libs/rc2base`-style, if a concrete program needs it.

Partial exception for `System.Random`: `libs/rc2base/src/System/
Random/` now provides two modules, `Xoroshiro64StarStar.idr` and
`Xoroshiro128PlusPlus.idr` (the latter rewritten from an earlier
pure-Idris xoshiro128++ port to a real xoroshiro128++ port) -- both
thin FFI wrappers around a C port of their respective reference
algorithm, and so, unlike a from-scratch pure-Idris replacement would
be, rc2/C-backend-specific rather than portable to every backend.
Neither is a `%foreign_impl` patch onto upstream contrib's own
`System.Random` primitives the way `System.Concurrency.RC2` patches
`System.Concurrency` -- those primitives (`prim__randomBits32`/
`prim__randomDouble`/`prim__srand`) remain entirely unimplemented on
any C backend, unfixed by this. Both stay separate modules with their
own API, deliberately not wired up as instances of upstream's own
`Random` interface, to avoid ambiguous instance resolution against
upstream `System.Random`'s existing instances for callers who import
both. See `libs/rc2base/README.md`'s own
"`System.Random.Xoroshiro128PlusPlus` / `System.Random.
Xoroshiro64StarStar`" section for the full API and design rationale.

Also patched since the above survey, unlike `System.Random`/
`System.Future` above: `Data.Buffer`'s five gap primitives
(`setInt8`/`getInt8`/`getInt16`/`setInt64`/`getInt64`) are now wired up
by `libs/rc2base/src/Data/Buffer/RC2.idr`, a `%foreign_impl` patch
(unlike `System.Random`'s from-scratch replacement) onto the existing
`rc2/support/rc2/buffer.h` macros this survey already noted could back
them. See `libs/rc2base/README.md`'s own "`Data.Buffer.RC2`" section
for the full API and design rationale, including a real
`Compiler.RC2.Emit` `CFBuffer`-unwrap bug this patch surfaced and fixed
along the way (`KNOWN-BUGS.md`'s own "Retired: ..." entry for that
fix).

Also patched: `Data.Double`'s `unitRoundoff`/`epsilon`/`nan`/`inf` are
now wired up by `libs/rc2base/src/Data/Double/RC2.idr`, a
`%foreign_impl` patch onto four new `rc2/support/rc2/numeric.h`
functions (no existing runtime support to reuse here, unlike
`Data.Buffer`). See `libs/rc2base/README.md`'s own "`Data.Double.RC2`"
section for the full API and design rationale, including the first
arity-0, non-`PrimIO` `%foreign` value this project has wired up.

## Performance: codepoint-indexed String access is O(n) per call, not O(1)

`String`'s primitives (`length`/`strIndex`/`strTail`/`strCons`/
`reverse`/`substr`/`pack`/`unpack`/`Data.String.Iterator`) were
rewritten to be Unicode-codepoint-, not byte-, indexed, matching
Idris2's own Chez backend (see README.md's "Deliberate differences
from upstream RefC" -- this used to be tracked here as a correctness
gap; now fixed, `rc2/support/rc2/utf8.c` is the shared codec every
primitive in `idris2rc2_strings.c` decodes/measures/slices through,
with each one's own comment there spelling out which real *byte* span
it allocates against so character and byte counts are never confused).

One accepted, deliberately unaddressed consequence of *how* it's
fixed: rc2 kept `String`'s existing UTF-8-byte-buffer representation,
so `strIndex`/`strSubstr`/`strTail` must scan from the string's own
start to translate a codepoint index into a byte offset -- O(n) per
call. Chez's own native string type is a fixed-width character array
(`string-ref` is O(1)), so this matches Chez's *semantics* without
matching its *performance characteristics*. Fixing that would mean
switching `String`'s internal representation entirely (e.g. UTF-32, or
caching a byte-offset table) -- a much larger change than this work's
own scope. Not currently planned; revisit only if profiling ever shows
codepoint-indexed access on a long string actually mattering in
practice.

## Dropped: packing short strings into a tagged pointer

Considered (as a future-hope wishlist item) extending rc2's existing
tagged-pointer scheme (`Int8`/`Int16`/`Int32`/`Bits8`/`Bits16`/
`Bits32`/`Char`, see `Compiler.RC2.Types.alwaysUnboxed` and
`support/rc2/datatypes.h`'s own module note) to short strings as well
-- packing a small enough `String` directly into the pointer word
itself, avoiding a real heap allocation (and its `idris2rc2_dup`/
`idris2rc2_drop` traffic) the same way these scalar types already do.

Dropped without implementing: a short string overwhelmingly shows up
in real Idris2 source as a *compile-time constant*, not a
runtime-computed value, and constant strings already get exactly this
class of allocation-avoidance treatment today -- `Compiler.RC2.Emit`/
`ConstFold` stage every literal `String` constant (short or long) as
an immortal, file-scope C static (`IDRIS2RC2_STOCKVAL`), never a fresh
heap allocation, with `idris2rc2_dup`/`idris2rc2_drop` already
no-ops against it (the `REFCOUNT_MAX` immortal check). Tagging short
strings would therefore buy nothing for the overwhelmingly common
constant case -- it could only help a short string that's *itself
computed at runtime* (e.g. sliced/concatenated dynamically) and still
happens to end up short, a narrow enough slice of real workloads that
the payoff looks marginal at best. Not investigated further, not
implemented; revisit only if profiling ever shows short,
runtime-computed strings actually dominating some real workload's own
allocation traffic.

## Cleanup: `freshId`/`freshName` duplication between `DualABI.idr` and `MutualLoop.idr`

`freshId` (a one-line `Ref`-backed counter bump) is byte-identical
between `Compiler.RC2.DualABI` and `Compiler.RC2.MutualLoop`, and was
considered for consolidation into `Compiler.RC2.Util` alongside
`rc2traverseVect`/`peelDrop`/`assignShadowIds`/`localRepIn` (see
`Util.idr`'s own module note). Not pursued in that round: each file
declares its own local phantom marker type `data FreshId : Type`
(`DualABI.idr`, `MutualLoop.idr`) to key its own `Ref FreshId Int`, so
merging just the function would still leave the two modules'
`Ref`s incompatibly typed -- consolidating `freshId` for real means
also sharing that phantom type across both modules, a bigger, more
invasive change for a two-line function's benefit. `freshName` is
*not* a safe merge candidate either way: `DualABI.idr`'s own version
takes an extra `pfx : String` and `original : Name`, `MutualLoop.idr`'s
own is fixed to `MN "rc2_mutualLoop" i` with no parameters -- a strict
generalisation, not an identical duplicate. Revisit both together if
`Compiler.RC2.Util` ever needs a shared fresh-id facility for a third
consumer.

## Scope: `Compiler.RC2.DeadCode` doesn't cover `MkRCForeign` removed by constant folding

`Compiler.RC2.DeadCode` (see `rc2/doc/dead-code-elim.md`) deliberately
never removes a `%foreign` declaration's own `MkRCForeign` entry --
argued there that, under `Inline`/`DualABI` alone, a `MkRCForeign`
entry surviving to this pass can never actually lose every caller
(`Inline` requires a callee to be call-free, so a function calling an
FFI declaration is never Inline-eligible in the first place; `DualABI`'s
wrapper/worker split keeps a function's own FFI calls alive inside
whichever of its wrapper/worker is still reachable).

That argument has a real gap: `Compiler.RC2.ConstFold`'s `RConstCase`
case-of-constant folding (`foldConst`'s `findConstAlt`) replaces the
*entire* case node with just the one matching alt's body once its
scrutinee resolves to a known constant, discarding every other alt's
body outright -- including any `%foreign` call inside it. This is
exactly what a codegen-identity branch (`prim__codegen`/`prim__os`
folded to a literal string, `Compiler.RC2.ConstExtPrim`) or a folded
comparison feeding a boolean `RConstCase` compiles down to. A
declaration whose *only* call site sits inside a branch eliminated
this way would genuinely lose every caller, `MkRCForeign` included --
`Compiler.RC2.DeadCode.pruneDeadDefs` would need to also track, for
`MkRCForeign` specifically, whether its own `ccs` still appears among
surviving `RAppFFIInline` splices (a mechanism that was actually
implemented and then removed during that pass's own development,
because every test constructed to exercise it went through `Inline`/
`DualABI` instead, where it never fires -- see `dead-code-elim.md`'s
own "Bugs found" #1 and the surrounding "Scope" section).

Not pursued: this needs an actual multi-target-`%foreign`/codegen-
branch test to hit deliberately, and is a narrow enough case (a
`%foreign` declaration with a *single* call site sitting inside a
statically-eliminated branch) that it wasn't judged worth the
complexity revival for now. Revisit by reintroducing
`usedForeignCCsR`/`usedForeignCCsD` (removed, not merely disabled) if
this ever turns out to matter for a real generated-C size/compile-time
concern.

## yet another hope
この項は人間が追加したものなので、後で整理して独立の項に括りだす事。
今は着手しないが将来的な展望を書き連ねる。この項は日本語で書かれるが
翻訳する必要はない。計画立案して項を独立した時に英語になっていればよい。

- Liftedはあまりメンテされていない？ラムダリフトの時に色々情報が欠落しているらしいので、
  NamedCExprからラムダリフトするところから自前でやった方がいいかもしれない。
- Cのレベルで無駄な代入が相変わらず発生している。Cコードの可読性を向上させたい
- カスタムメモリアロケータに対応したい。例えばpythonに組み込む時にpython側
  のアロケータを使えれば効率化につながるのでは？
- slabの様にfree-list風に高速割り当てできる固定アロケータを使えるようにしたい。
- libgc板のランタイム。dup/drop/freeをCマクロで消去してしまい、mallocを単純に差し替える
  だけでlibgc対応できるのでは？
- **Performance: Closure Inlining and Immediate Expansion**
  `partial`呼び出しによるクロージャ生成とヒープ割り当てが、高階関数や型クラスの辞書使用時に頻発している。特に`List`操作や`mapAppend`のような高階関数において、`Boxed`なクロージャが多重生成されており、パフォーマンスを大きく阻害している。
  - 可能な限りコンパイル時にクロージャを特定し、直接呼び出しへとインライン展開するパスを実装する。
  - スコープ内で閉じている静的な定数クロージャは、最適化パスで完全にインライン化・削除を行う。

- **Performance: Higher-Order Function Specialization**
  `mapAppend`のような汎用的な高階関数は、すべて`Boxed`な値を引数に取るため、頻繁なポインタ参照とヒープ割り当てが発生している。
  - 特定の型（例：`List Double`）に対して高階関数が呼び出されている場合、コンパイル時に型特化した関数を生成する（テンプレート化/マングリング）。
  - 特化により、`Boxed`なCONSセル走査を、ネイティブな配列走査へと置き換え、参照カウント操作を削減する。






