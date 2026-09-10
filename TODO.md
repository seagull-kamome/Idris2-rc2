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

Fixed -- see `rc2/doc/loop-conversion.md`'s "Known limitation" section
for the closed case (`calleeNativeParams`/`buildCalleeTable`/
`callArgNativeTypes`/`callArgOrOpNativeType`) and its two remaining,
deliberate scope limits (one call hop only; variant loop parameters
only). The return side (a native-returning helper's own result boxed
only to be immediately unboxed again for the next iteration's carried
shadow) is now fixed too -- `Compiler.RC2.DualABI`'s
`loopContinueNativeReads`, see the same doc section's updated
paragraph and `rc2/tests/Test57LoopCallArgNativeShadow.idr`, which
also absorbed the former `Test58LoopContinueNativePromotion.idr`'s
dedicated coverage for this case.

## Future: nested self-tail-recursive loops

`Compiler.RC2.Loop`'s `applyLoop` assumes a function has at most one
`RLoop` -- relied on directly by `fillLoopContinuePostDrop` and by
`Compiler.RC2.DualABI`'s own `loopContinueNativeReads` (a single
`Maybe (List (Int, Rep))` slot for "the enclosing loop's own
`loopParams`", not a stack). A genuinely nested self-tail-recursive
loop (one loop's own body containing another, independent
self-tail-recursive loop) isn't something `applyLoop` currently
produces or expects, so this invariant holds today -- but if nested
loop support is ever added, every one of these single-loop
assumptions needs revisiting (at minimum: `loopContinueNativeReads`'s
own `Maybe (List (Int, Rep))` would need to become a stack keyed to
the *innermost* enclosing loop, since a `RLoopContinue` found while
walking one loop's body must never be matched against an outer loop's
own `loopParams`).

## Performance: `Loop.idr`'s own loop-carried (non-invariant) native shadow still reboxes fresh on a Boxed-context read

Fixed for `Compiler.RC2.ConAltNative`'s own destructured-field caching
(`rc2/doc/con-alt-native.md`'s "Reusing the original Boxed field for
surviving Boxed-context reads" section) and for `Compiler.RC2.Loop`'s
own loop-*invariant* parameter hoisting (`rc2/doc/loop-conversion.md`'s
"Reusing the original Boxed value for a surviving Boxed-context read"
section) -- both `dup` the original Boxed value on a surviving
Boxed-context read now, instead of `Emit/Util.idr`'s `rcVarToBoxedC`
default cost (a fresh `nativeMk` allocation every time).

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

## Performance: closure-dispatch fast path doesn't cover arity > 20 (`FUNSTAR`)

`idris2rc2_applyClosure`'s new fast path (`rc2/doc/closure-dispatch-optimization.md`)
skips allocating a transient `IDRIS2RC2_Closure` when a non-unique
closure receives its final argument, but only for arity `1..20` -- the
typed `IDRIS2RC2_FUNn` range `idris2rc2_dispatchWithExtra` implements.
A closure with arity greater than 20 still takes the old
`mkClosure`-then-trampoline-then-teardown path via the generic,
array-based `IDRIS2RC2_FUNSTAR` calling convention. Deliberately left
out of this round's scope, not an oversight.

The same allocation-skip idea could in principle extend there too:
`FUNSTAR`'s calling convention just needs a contiguous
`IDRIS2RC2_Value **` array to hand the target function, and that array
doesn't need to be heap-allocated -- arity is always a fixed,
known-small constant even past 20 (an actual runtime value, read off
`c->arity`, but bounded at compile time by whatever the largest arity
in the program happens to be), so a small stack buffer (e.g. a
fixed-size local array, or `alloca`, sized to the program's own known
maximum arity) would work just as well as `idris2rc2_mkClosure`'s heap
allocation, without needing the closure object itself. Not attempted;
see `rc2/doc/closure-dispatch-optimization.md` for the full context on
the existing 1..20 fast path this would extend.

## Dropped: loop-invariant constructor-field hoisting

Two entries, investigated and dropped together -- "loop-invariant
single-branch case hoisting" and `ConAltNative`'s once-planned
extension "across loop/dual-ABI boundaries" turned out to be the same
underlying gap wearing two different names. See
`rc2/doc/case-hoisting-scope.md` for the full writeup (why it looked
worth doing, what the investigation found, and why neither design
considered was pursued).

## Performance: interface-dictionary method dispatch stays boxed even when the concrete instance is known

Investigated against a real workload (`idris2-missing-containers`'
`benchmarkHash`, five `HashAlgorithm` instances -- FNV1a/MurMur3/
OneAtATime/Sip32/Sip64 -- all sharing one generic
`Data.Hash.Algorithm.Internal.feedCharOfString`, called once per byte
per word per algorithm): every interface-method call (`feed8`) goes
through a boxed `idris2rc2_applyClosure` dispatch, even though each
concrete instance's own `feed8` compiles to a genuinely native
`Compiler.RC2.DualABI` worker (`uint64_t`/`uint8_t` in and out, no
internal boxing at all -- confirmed directly in the generated C).
The cost is real and concrete, not theoretical: `rc2/BENCHMARKS.md`
already measured this hot path as the dominant cost in that
benchmark.

Root cause, confirmed via the actual generated C
(`install/idris2-missing-containers/test/src/build/exec/mct_rc2.c`):
the `HashAlgorithm` dictionary itself was built by a top-level 0-arg
CAF (`csegen_41`) that allocated a fresh 6-field `IDRIS2RC2_Constructor`
plus six fresh `idris2rc2_mkClosure`'d partial applications -- on
*every call*, never memoized (rc2 has no CAF-sharing at all, see the
"Lazy/Force" section below).

**Now solved: the dictionary's own construction cost.** Commit
`a01eaa2` adds a new `RCConstClosure` constant form to
`Compiler.RC2.ConstFold` for a bare, zero-filled closure over a named
top-level function (`RUnderApp fc n missing []`). The existing
`allConstLocal` check (`RCExp.idr`'s `IsAnyConstLocal`) that used to
accept only `RCNull`/`RCConst`/`RCEmptyCon`/`RCConstCon` fields --
never a closure -- now also accepts `RCConstClosure`, so `RCConstCon`
folding reaches straight through `csegen_41`'s own six closure-shaped
fields with no cross-CAF-boundary work needed at all (the fold
operates on `csegen_41`'s own body, where the dictionary's `RCon` is
actually built). `csegen_41`'s whole body now collapses into one
immortal static; the six `mkClosure` calls plus the constructor
allocation are gone. Full design, the `Compiler.RC2.DeadCode`
correctness gap this exposed, and the related pre-existing
`Emit.Util.boxedConstExpr` dedup bug it exposed: see
`rc2/doc/const-closure-fold.md`.

**Still open: per-byte dispatch through the dictionary.** The fix
above only makes *obtaining* the dictionary free -- every `feed8` call
still reads a field out of it (`RCLoc`) and dispatches through boxed
`idris2rc2_applyClosure`, entirely unchanged
(`rc2/doc/const-closure-fold.md`'s own "Scope / limitations" is
explicit that this was never in scope for that fix). Resolving *that*
call to a direct call to (e.g.) `FNV1a`'s own concrete `feed8` worker
is a different, still-unaddressed problem, blocked on:

- **`Compiler.RC2.Inline`'s call-free criterion still excludes
  dictionary construction**: `csegen_41`'s own body is six
  `LUnderApp`s (closure constructions), and `isCallFree (LUnderApp {})
  = False` unconditionally -- by design, per `rc2/doc/inlining.md`'s
  own "Eligibility: Criterion A only" scoping. Not a blocker for
  folding the dictionary itself (ConstFold reached that independently
  of Inline, above) -- still a blocker for using Inline as an
  alternate route to carry the now-known-constant value into a caller.
- **Nothing propagates the dictionary's now-known constant value
  across a function-call boundary**: the value would still need to
  survive *interprocedurally* -- as an ordinary argument into
  `feedCharOfString`, then into its own self-tail-recursive `go`
  loop's own loop parameter -- before a rewrite could resolve the
  `args[1]`-extraction + `apply` pair into a direct call.
  `Compiler.RC2.Loop`'s native-shadow/invariant-parameter promotion
  has no notion of "this loop parameter is a provably-constant
  closure" today (a closure is always `RBoxed`, and `Loop.idr`'s own
  invariant-hoisting explicitly excludes `RBoxed` results for an
  unrelated, already-fixed double-free reason -- see "`Loop.idr`'s own
  loop-carried... native shadow" above). And because `feedCharOfString`
  is *shared* by all five instances, resolving this for one instance
  means **cloning** the shared helper (and its loop) per distinct known
  dictionary, not rewriting in place -- the same per-call-site
  specialization/cloning cost (unbounded generated-code growth from
  minting a near-duplicate copy per distinct argument) that rules out
  doing this generically for an arbitrary statically-known
  higher-order-function argument, though bounded here by however many
  *instances* of an interface actually get used in a program (typically
  small and enumerable), rather than by every possible function value a
  generic higher-order helper might ever see.

**A narrower fix was also investigated and found insufficient**: since
a dictionary's own method fields are always freshly built with
`filled = 0` (never partially applied within the dictionary itself)
and a closure's own `fn` pointer is immutable once set
(`idris2rc2_mkClosure`, confirmed no other write site exists), reading
`->fn` out as a new native ("no refcount needed, unlike a real
`IDRIS2RC2_Value*`") `Rep` case and calling it directly, bypassing
`idris2rc2_applyClosure` entirely, is sound -- but *only* for a
closure's *final* remaining argument, which is exactly what
`rc2/doc/closure-dispatch-optimization.md`'s existing
`idris2rc2_dispatchWithExtra` fast path already covers. `feed8` itself
is arity 2, applied in two sequential steps (accumulator, then byte)
per `RApp`'s own one-argument-at-a-time shape -- rc2's IR has no node
for "apply K remaining arguments to an existing closure value in one
step" -- so the *first* application (accumulator, 2 args still
remaining) can't benefit from this trick at all: it still needs a real
persisted intermediate object (the closure is `dup`'d fresh from the
shared dictionary every loop iteration, so it's never unique at that
point either). This narrower angle is complementary to, not a
substitute for, the specialization problem above -- it only ever
helps the *last* step of a dispatch chain, not the earlier ones.

Not pursued: a real fix now needs propagating the dictionary's known
constant value through a loop parameter (an independently-documented
`Loop.idr` gap) and call-site-sensitive cloning of the shared generic
function per distinct known dictionary -- a coordinated, multi-pass
effort rather than a bounded extension of any single existing pass.
Revisit if profiling on a real workload continues to show this
dominating (already true for `idris2-missing-containers`, per
`rc2/BENCHMARKS.md`).

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

## Semantics: a plain `unsafePerformIO` CAF isn't memoized either -- same root cause, now with a real-world hit

The "Semantics: `Lazy`/`Force`..." entry above already traced the root
cause (`idris2-src/src/Compiler/LambdaLift.idr`'s `getCompileData
doLazyAnnots = False`, plus rc2/RefC's complete lack of CAF-sharing for
top-level 0-argument definitions -- confirmed there via
`System.Random.Xoroshiro128PlusPlus`'s own global-state design) and
noted "every use of `Lazy`/`force` in this codebase's own source...
happens to be single-use, so it hasn't caused an observed problem."
That changed while building `libs/rc2base`'s `Network.HTTP.Server`
(see its own `doc/http-server.md`): a test program used the ordinary,
`Lazy`-free pattern

```idris2
counter : IORef Int
counter = unsafePerformIO (newIORef 0)
```

expecting one shared `IORef` the way `--cg chez` gives (confirmed:
prints `0 1 2` for three successive reads/increments there). Both
`--cg rc2` and upstream's own `--cg refc` instead print `0 0 0` --
three independent `IORef`s, since the CAF compiles to an ordinary
zero-argument function re-run on every reference, the identical root
cause as the `Lazy` entry above but hit here with no `Lazy`/`Force`
involved at all -- just a bare top-level value built through
`unsafePerformIO`. Confirmed side-by-side across Chez/RefC/rc2 before
writing this up, specifically to rule out an rc2-specific regression.

Not a new bug, not fixed here -- same "not pursued" conclusion as the
entry above (a real fix needs the same CAF-sharing + memoizing-closure
work). Recorded separately because this is the first time it's
actually bitten real code in this repo rather than being a theoretical
gap: `Network.HTTP.Server`'s own doc warns its users off the pattern
directly (create the `IORef` in `main`, pass it into the handler
instead of reaching for a top-level CAF); no compiler-side mitigation
attempted.

## Upstream stdlib `%foreign` declarations with no C/RefC backend at all

Surveyed every `%foreign` declaration in `idris2-src/libs` (206 across
27 files, `base`/`prelude`/`contrib`/`network`) for ones carrying no
`"C:..."`/`"RefC:..."` alternative whatsoever. Anything without a
C-tagged alternative is a function the *pinned reference*
`idris2 --cg refc` itself cannot call at all -- not an rc2-specific
gap. Four such spots found, all upstream:

- **`Data.Buffer`**: `setInt8`/`getInt8`/`getInt16`/`setInt64`/
  `getInt64` -- patched, see `libs/rc2base/README.md`'s
  "`Data.Buffer.RC2`" section.
- **`Data.Double`**: `unitRoundoff`/`epsilon`/`nan`/`inf` -- patched,
  see `libs/rc2base/README.md`'s "`Data.Double.RC2`" section.
- **`System.Random`** (contrib): `prim__randomBits32`/
  `prim__randomDouble`/`prim__srand` (backing the whole module) remain
  entirely unimplemented on any C backend. Not a `%foreign_impl` patch
  onto them (unlike `Data.Buffer`/`Data.Double` above) -- see
  `libs/rc2base/README.md`'s "`System.Random.Xoroshiro128PlusPlus` /
  `System.Random.Xoroshiro64StarStar`" section for two independent,
  from-scratch replacement modules with their own API instead.
- **`System.Future`** (contrib): `prim__makeFuture`/
  `prim__awaitFuture` carry only a `"scheme:..."` tag -- entire module
  unusable on any C backend, refc included, and genuinely
  un-investigated: hasn't surfaced as a real blocker for any program
  built against rc2 so far. Revisit with a `%foreign_impl` patch or a
  from-scratch replacement, `libs/rc2base`-style, if a concrete program
  needs it. Not to be confused with rc2's own, unrelated joinable fork
  (`forkJoin`/`join`/`JoinHandle`, `rc2/doc/concurrency.md`'s "Design:
  joinable fork").

One more single-function case surfaced by the same survey,
`prim__threadWait` (`libs/prelude/Prelude/IO.idr`) -- not a fresh
finding, it's the same gap `rc2/doc/concurrency.md`'s "Design: joinable
fork" section already documents at length -- included here only so
this survey is a complete index.

## Performance: codepoint-indexed String access is O(n) per call, not O(1)
CStringを他バックエンドと揃える為にutf8バイト列にした為、indexの計算コスト
が酷く劣化。
Data.TextBufferを用意すると共に、長らく動いていなかった文字列イテレータを
整備する事で回避策としたが、まったく透過的でないのは気に入らない。
かといって、chez等のようにStringをコードポイント列としてしまうと、FFIの
オーバーヘッドで更に気に入らない事になりそう。
コード解析して透過的に昇格/降格する事も考えたが、文字列操作で予測困難な
見えないオーバヘッドが挿入される事になる。


## Performance: `Double <-> String` cast has no fast path (GMP every call)

`support/rc2/numeric.c`'s `idris2rc2_cast_string_to_Double` /
`idris2rc2_cast_Double_to_string` are correct and locale-independent
(GMP-exact rational parse; shortest-round-trip formatter that probes
precisions 1..17), but every call allocates GMP temporaries -- fine for
`show`, not for parsing a large numeric data file. The standard fast
path is a branch-free `uint64_t`/`__uint128_t` route: Eisel-Lemire
("fast_float" / Go `strconv` / Rust) for the parser, Grisu2 or Ryū for
the formatter, with the current GMP code kept as the slow-path
fallback. Deferred deliberately -- decided the simple GMP-only version
first, fast path later. No behaviour change when it lands, only speed.
See `rc2/doc/runtime-lifecycle.md` and `numeric.c`'s own comment.


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
exactly what a codegen-identity branch (`prim__codegen` folded to a
literal string by `Compiler.RC2.ConstFold`'s `constExtPrimValue`) or a
folded comparison feeding a boolean `RConstCase` compiles down to. A
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

## `libs/rc2base`'s `Data.Integer.GMP` doesn't cover every `mpz_*` function

Deliberately scoped to two shapes only (see that module's own header
comment and `libs/rc2base/README.md`'s own section for the full
reasoning, not restated here): a single leading `mpz_t` out-parameter
with a `void` return, or a plain native return with no output
parameter at all. Several real GMP functions don't fit either shape
and are excluded rather than force-fit:

- `mpz_setbit`/`mpz_clrbit`/`mpz_combit`: mutate their *single* `mpz_t`
  argument in place, no separate `rop`/`op` at all -- confirmed as a
  real compile error when tried the same way as everything else
  (generates one argument too many). A real binding needs a wrapper
  that copies first (`mpz_init_set` into a fresh destination, then
  mutate that copy) -- the one case in this module that would need one
  at all.
- `mpz_invert`/`mpz_root`: a leading `mpz_t` out-param *and* a
  meaningful `int` return (invertibility/exactness) at once.
- `mpz_tdiv_qr`/`mpz_fdiv_qr`/`mpz_cdiv_qr`/`mpz_gcdext`: more than one
  output parameter (quotient+remainder together, or gcd+both Bézout
  coefficients).
- GMP's random-number API (`mpz_urandomb`/`mpz_urandomm`/etc.): needs
  an opaque `gmp_randstate_t` with its own init/clear lifecycle --
  separate design work, not an extension of this module's own
  direct-binding convention.

Not pursued further this round -- none of these came up against a real
need, and each would cost more than a one-line `%foreign` declaration
(the whole point of what's already there). Revisit if a concrete use
case needs one specifically.

## インクリメンタルコンパイル（実装済み・動作確認済み）
`feature/rc2-incremental-compile`ブランチで実装完了。prelude/base/
linear/contrib/network（272モジュール）全てエラーゼロ・欠落ゼロで
`--inc rc2`ビルド可能、`--cg rc2 --inc rc2`での実際の実行ファイル生成・
実行（base機能のData.List/Data.SortedMap使用例含む）・1ファイル変更時の
差分ビルドまで確認済み。設計・実装過程で見つかった全バグ・制限事項は
`rc2/doc/incremental-compile.md`に記録（upstreamの
`Codegen.incCompileFile`/`incExt`機構をrc2に実装する話。ConstFold/
Loop/MutualLoop/DualABIは無改造で済んだ）。

- **制限事項（決定事項）**: `--inc rc2`（インクリメンタルコンパイル）は
  当面C構造体サポート（`getField`/`setField`/`Struct`）に非対応。
  `getField`等の薄いラッパーはインライン展開されて初めて
  `prim__getField`のリテラル要求を満たせる設計のため、DCEをスキップする
  インクリメンタルモードでは単体コンパイル不可能（同docの「Known
  limitation」節参照）。ホールプログラムコンパイル（デフォルト）は無影響。
- 実運用にはprelude/base/contrib/networkをrc2向けにインクリメンタル
  再ビルドする一度切りの前提作業が要る（同docの該当節参照）。
- **重大な発見（rc2固有のバグではなくupstream側の性質）**: `incCompile`は
  モジュール単位とはいえ実際に`.c`生成→`gcc -c`まで行う（中間表現止まりでは
  ない）ため、`%foreign`宣言があれば通常のホールプログラムビルドと全く
  同じくCヘッダ・ライブラリが必要になる。パッケージ内のたった1モジュールが
  （今回は`idris2-src`自身の`support/c/idris_file.h`に`idris2_fileIsTTY`の
  プロトタイプ記載漏れがあったため——実装自体は`idris_file.c`にあり、
  selfビルドも正しく機能している。ホールプログラムでも`isTTY`を使えば同様に
  失敗するはずだが、DCEで消えるため今まで誰も気づかなかっただけ）オブジェクト
  生成に失敗すると、`Core.Context.addImportedInc`がセッション全体で`rc2`を
  `incrementalCGs`から削除してしまい、**同じビルド中でそれ以降処理される
  全モジュール**（失敗モジュールと依存関係が無いものも含む）がインクリ
  メンタルデータを失う。実際`base.ipkg`（136モジュール）で検証したところ、
  1モジュールの失敗が原因で136中100モジュールがデータ欠落した。警告は
  カスケード開始時に1回しか出ないため気づきにくい（同docの「Major
  finding」節参照）。対処方針は未定（rc2側で回避するか、単に「1件でも
  失敗したら再度`--install`を回す」運用でしのぐか等）。


## 融合変換のインジェクション
%transfor同等のものをバックエンドで持っておいてインジェクションできるようする。
  - CExpの時点で変換する
  - codeGenや、fastPack, fastConcatの読み替えもこの段階で処理できるようにする。
  - rc2baseに RC2 の名前で置いた定義も不要にしたい
    -> 上流に持っていけない定義をブラックリスト化し、不本意だがコンパイラ側で強制的に読み替えを行うようにできれば....

## %world 引数, Erased の引数を削除
  - 無駄でしか無いので消せるものなら消したい
  - 最適化効果は薄い。気分の問題でしかない。

## Lambda lift で欠落する情報の保全
現状、遅延評価についての情報が消えてただのクロージャになってしまう。
保全してメモ化やインライン展開をしたい。
新しい Lifted を定義し、NamedCExp からの Lamda lift を自分でやるしかないか？

  - 現在のLiftedでも、Force が無いだけでLazyは注釈として情報が残る
  - 特殊なクロージャを用意して型タグを使って実行時にメモ化を解決できる？
  - トップレベルの引数の無い関数はstaticで価をメモ化できる？
  - && や || のインライン化は調査済み・対応不要と判明(下記「遅延評価引数を持つ
    小さい関数のインライン展開」参照)。他の`Lazy`引数関数についても同様の
    upstream最適化が効くかは未調査。

## キャッシュ付き固定サイズメモリアロケータの導入
小さいサイズの構造体確保が頻繁に発生するので、アロケーションサイズに応じて
拘束な固定サイズアロケータを使う拘束パスを用意する。
  - サイズ別スロット
  - 事前割り当て
  - atomic なフリーリスト割り当てで高速化

## カスタムランタイム、メモリアロケータ
そもそもアロケータやdup/dropの仕組みやランタイム丸ごとすり替える事ができれば
世代別 GC 等の恩恵をほぼ無料で受けられるのでは？
  - 他処理系への組み込みを行なったときに、ホスト側処理系のランタイムを利用できる


## ファントム型やファントム関数の明示
トップレベル定義に 0 をつける。
実行時に存在しないからいいや、ではなく存在しない事を保証する

## RCExp の ROp はRLocalに持っていく -- 調査済み、却下

調査の結果、これは冒頭の「Architecture: RCLocal can't hold another
RCLocal」で一度却下された`RCStructField`案と全く同じ問題(RCLocalへの
ネスト)であり、しかも規模・リスクの両面でそれを明確に上回ることが
判明した:

- `RCStructField`案は「1個のネストしたRCLocal、副作用なし」だったが、
  `ROp`は`Vect arity RCLocal`全体をネストし、しかもROpが自分自身を
  再帰的に埋め込め、`postDrop`という実効果(参照カウント解放)を持つ
  フィールドまで持つ。`RCExp.idr`の`freeLocalsR`/`countUsesR`、
  `RC.idr`の`splitBorrows`/`dropIfLastUse`/`boxedOperands`/`annotate`、
  `Sink.idr`の`genuinelyUsedR`、`Loop.idr`の`renameLocal`(サイレントな
  リネーム漏れという新種のバグ経路が判明)、`ConAltNative.idr`/
  `DualABI.idr`の各所――ほぼ全パスで実質的な書き換えが必要。
- 調査で新たに判明した障害: `Emit/Util.idr`の`rcVarToBoxedC`/
  `rcVarToNativeC`は「文を発行できない純粋文字列関数」という契約で
  20箇所以上から呼ばれており、ROpをネストした値として埋め込むと
  この契約と正面衝突する。過去に実際踏んだ`postDrop`順序バグ
  (`doc/native-type-inference.md`のBug #4、use-after-free)を埋め込み
  位置の数だけ再現しかねない領域。
- `inlineableRep`(`RC.idr:544-547`)の「厳密に1回しか使われない」検証は
  ROp案でも消えず、単に検証の置き場所が変わるだけ――「InlineNativeが
  不要になる」という期待は成立しない。

**朗報**: 目的(Cに生成される変数の削減)自体は、`postDrop==[]`な
ネイティブ演算チェーンについては既存の`inlineableRep`+`InlineMap`
機構(`RC.idr`/`Emit/Util.idr`/`Emit.idr`)で既に達成済みと確認した。
残る唯一の実質的ギャップは、`inlineableRep`が`postDrop == []`を
要求する(`RC.idr:545`)ため**Boxedオペランドを1つでも読むROpは、
使用回数が1回でも絶対にインライン化されない**という制約。

**追記(実装検討の結果、規模を訂正)**: 上記ギャップの解消は`RCLocal`
型自体には触れないものの、当初見込んでいた「桁違いに小さい改修」
ではなかった。`inlineNative`(`Emit.idr:453-456`)は式文字列を
`InlineMap`に登録する**その時点で**`removeVars pending`を実行して
しまうが、その式が実際にインライン展開される(後で参照される)場所は
別のタイミングであり、`postDrop`が非空だとdropが式の実際の使用より
先に発行され use-after-free になりうる。安全にするには「dropの発行
を実際の展開時点まで遅延させる」設計変更が要るが、`inlineExprFor`
(`Emit/Util.idr:942-958`)から式を取り出す全経路(`rcVarToBoxedC`/
`rcVarToNativeC`、呼び出し元だけで**49箇所**)が「Cの文を発行できない
純粋文字列関数」という契約になっており、これを破らずに戻り値へ
pendingリストを伝播させる形にすると、49箇所全てで「ここでdropして
よいか」を個別に精査する規模の変更になる。着手するかは保留。

**追記2(実装した)**: 上記の懸念(49箇所への影響)を検証した結果、
実際に型変更の直接波及を受けたのは`rcVarToBoxedC`/`rcVarToNativeC`の
呼び出し元(実質約30箇所、間接的に`emitRC`自身の契約も道連れになった
-- 後述)にとどまった。`InlineMap`を`SortedMap Int (String, List
String)`(式文字列+pendingのペア)に変更し、`inlineNative`は登録時に
即`removeVars`せずpendingをそのまま保存、`rcVarToBoxedC`/
`rcVarToNativeC`はInlineMapから読んだpendingを自分の戻り値として
呼び出し元に返すよう変更。1点、当初の見積もりに無かった追加の波及が
判明した: `emitRC`自身がいくつかのケース(RApp/RConなど)で複数の
`rcVarToBoxedC`呼び出し結果を*まだCの文として発行していない式*として
組み合わせてから`pure`で返しており、この場合pendingを安全に discharge
する場所が`emitRC`の外(呼び出し元の`emitInto`)にしかない。対策として
`emitRC`に`Sink`を渡し、内部で(新設の`finalizeSinkWithDrop`まで)
完結させる設計に変更 -- `emitAppNameRepInto`が既に持っていた「postDrop
空なら素通し、非空かつSinkReturnなら一時変数経由」というロジックを
共通ヘルパーとして切り出し、`emitRC`にも同じものを適用した。これに
より`emitRC`の外部呼び出し元は`emitInto`内の1箇所のみで、二次波及は
そこで止まった。`RC.idr`側は`inlineableRep`のパターンを`ROp _ _ _ _
[]`から`ROp {}`(任意のpostDrop)に緩和するだけで済んだ。

フルテスト(111 passed, 0 failed, valgrind clean)は全て通過 -- ただし
1件、`refc-suite`の`callingConvention`が生成Cコードの意図した変化
(ループ内の`op +`が新たに単一使用インライン化された)で期待値
ファイルとの単純diffが不一致になったため、その`expected`を更新して
対応(バグではなく、この変更が実際に効いている証拠)。

**実際に`postDrop != []`のROpがInlineNativeへ昇格される例**(狙って
`--directive dumprcexpr`で確認)は、Idris2フロントエンドの変換(let-
lifting、`Compiler.RC2.Loop`のネイティブシャドウ昇格)との相互作用で
見た目より起こしにくいと判明: `annotate`(Phase 2)は`Compiler.RC2.Loop`
より前に走るため、`RLoop`/`RLoopContinue`化される前の素の再帰呼び出し
形に対して`inlineableRep`を判定しており、`Loop`が後からその変数を
ループパラメータとして扱い直す際に`RInlineNative`判定を`RNative`へ
差し戻すケースを実際に確認した(`v5 : Native Int`のまま、直接の`ROp`
かつ1回しか使われないのに昇格されない)。一方、非ループの単純な関数
(`callingConvention`の`sumLoop`)では実際に発火し、正しく動作している。
実利(削減できるC一時変数の実数)を計測するところまでは踏み込んでおら
ず、`Loop.idr`側の相互作用まで手を入れるかは別判断。安全性(テスト
green、valgrind clean)は確保済みなのでこの状態でコミット、実利計測や
`Loop.idr`側の追随は必要になった時点で再訪する。

**さらに調査(Emit.idr/Emit/Util.idr全体のmutual簡略化を検討)**:
上記の作業前提としてEmit.idr(2102行)/Emit/Util.idr(1630行)自体の
簡略化を検討したが、結論は「大掛かりな着手は見送り」。Emit/Util.idr
の`mutual`(3関数)は既に100%真の循環で対象外。Emit.idrの`mutual`
(18関数、~1140行)は他の7モジュールと異なり15/18(83%)が単一の
真の強連結成分で、削減見込みはmutual全体でも高々30-50行
(全体の1.5-2.5%)。唯一安全に抽出できた`emitRC`/`emitAppNameRepInto`/
`emitAppFFIInlineInto`(一方向依存のみ)の3関数はmutualの外に出した
(コミット済み)。残り15関数は無理に`where`化しても`emitInto`が
320-350行に肥大化するだけで複雑度は減らない。このモジュールはC生成
の最終段階で、上記の`postDrop`タイミング問題がまさにここで実際に
起きうる領域であり、大きなコード移動によって暗黙の評価順序が
崩れるリスクの方が、得られる行数削減より大きいと判断した。

## Reuse解析とannotation(所有権挿入)の配置 -- 調査済み、方針決定

3案を調査した:

1. **ReuseをRC.idrのannotateに融合** -- 却下。`Reuse.idr`の核心
   (`resolveAlt`/`tryConsume`)は`annotate`が計算したRDropの値そのものを
   読む後処理であり(`peelDrop`の不変条件)、技術的には融合可能だが
   削減できるのは1定義あたり高々1walkのみ。専用モジュール・専用バグ史
   ドキュメントの単一責務性を失うコストの方が大きく、見合わない。
2. **annotate+Reuseをより後ろ(ConAltNative後、Loop/Sink後)に動かす**
   -- 却下。`ConAltNative`は`RReuseOffer`の一意性チェックが先に確定
   していることが前提(過去に順序を誤りvalgrindでリークが実証された
   バグ史あり、`doc/con-alt-native.md`のBug#2)。`Loop.idr`の
   `isInvariantExpr`はループ不変式ホイストの安全ガードとして
   `RCon.reuseFrom == Nothing`を直接読んでおり、Reuseが後回しだと
   このガードが常に無意味になる(`Loop.idr:713-716,727`)。
3. **所有権解析(annotate)全体を、ConAltNative/MutualLoop/Loop/Sink/
   DualABIといった構造変換パスより後ろに送る**(「構造変換パスが所有権
   情報を壊さないよう気を遣う負担自体を無くす」という発想) -- 6パス
   個別に「所有権情報を読んで判断に使っているか、単に構造として保持
   しているだけか」を精査した結果、`Loop`の`reuseFrom`依存(上記2と
   同じ)と`Sink`の`postDrop`/dup内容依存(`Sink.idr:120-135`、
   `doc/branch-sinking.md`の"second real bug"がまさにこれの読み落とし
   によるvalgrind確認済みリーク)という2つの真の消費点があるため、
   丸ごと後回しにする強い形は不成立。`MutualLoop`/`DualABI`は完全に
   所有権非依存(現状のままでよい)。

**見つかった案 → 実験実装済み、valgrindで失敗、要再設計**: `ConAltNative`
の適格性判定自体はPhase 1出力だけで完結し所有権情報に一切依存しない。
現在`ConAltNative`が抱える`peelWrappers`(RDup/RDrop/RFree/RReuseOffer/
RReleaseReuseを踏み越える処理)と`reannotateFieldOwnership`/
`finalizeBranch`(annotateの規則をそのまま再実装したミニannotate、
約120行、`ConAltNative.idr:43-54,136-254`)は、「ConAltNativeが
annotateの*後*に走るせいで、既に決まった所有権を壊さず部分的に
再計算する」ためだけに存在する、という見立てのもと、`ConAltNative`を
annotate/Reuseより"前"(normalize直後)に動かす実験を
`experiment/conaltnative-before-annotate`ブランチで実装した
(コミット`b6b334f`、masterにはマージしない)。

**結果: `rc2/tests/verify.sh --no-valgrind`は63件全通過(出力は正しい)
だが、valgrind込みで`Test12ConAltNative`が6,397,600 bytesのリークで
失敗。** 原因は`step (MkAcc x y) = MkAcc (x + 1) (y + 2)`
(destructureして即座に同じ形で再構築、Reuseとの相互作用を突く
ケース)で顕在化: 新しい`ConAltNative`が挿入する
`RLet fc sid (RNative ty) (RV fc (RCLoc p)) body`(Boxedな`p`を
ネイティブshadow `sid`へ読み込む)という形を、`annotate`の汎用`RV`
処理(`RC.idr:498-499`)が「`p`がまだownedならdup無しでそのまま」=
**move**として扱ってしまう。しかし本来これは`p`自身の参照カウントを
消費しないただの**borrow**であるべき。一方`branchBody`の
`freeLocalsR`チェックは`RLet`の`value`に現れる`p`を見て「使用済み」
と判定し、alt冒頭の無条件drop対象にも入れない。結果、「使用中だから
触らない」路線でも「もう死んでいるから今dropする」路線でも`p`を
dropする指示がどこにも生成されず、静かにリークする。元の(この実験で
削除した)`reannotateFieldOwnership`は、まさに「native読み取りは
所有権を消費しない」ことを正しく理解した手動再計算だったため、この
穴が最初から存在しなかった。

**次に検討すべき方向(未着手)**: 修正するなら`annotate`のRLet/RV
処理そのものに「valueがネイティブ表現letへのborrow読み取りである」
ことを認識させる拡張が必要になるが、これはConAltNativeの出力に
限らずプログラム中の*全ての*`RLet`に影響する共有ロジックの変更に
なるため、影響範囲の見極めが実装前に要る。あるいは、ConAltNative
側で`p`を明示的にdupしてからnativeに変換する(実行時コストは1回の
dup+dropペア分増えるが、正しさは保たれる)という保守的な代替案も
検討の余地がある。

## 遅延評価引数を持つ小さい関数のインライン展開 -- 調査済み、`&&`/`||`は対応不要

`&&`/`||`(`Lazy Bool`引数)がインライン展開されずクロージャ化されるのでは、という
懸念を実際にコンパイルして確認したが、問題は起きていなかった。upstream自身の
`%inline`プラグマとモジュールコンパイル時の`compileAndInlineAll`が、rc2独自の
`Compiler.RC2.Inline`が動くより前に、完全飽和呼び出し・部分適用いずれのケースでも
`&&`/`||`とそのクロージャを跡形もなく消し去っている(`--directive dumprcexpr`の
ダンプで実証: `Prelude.Basics`への参照が残らず、単純な`RCmpCase`の入れ子、部分適用
は恒等関数にまで簡約される)。rc2独自の`Inline`パス自体は`isCallFree`が`Force`由来の
`LApp`を含む本体を弾くため`&&`/`||`をインライン化できないが、その手前で解決済みの
ため実害なし。両辺が(プリミティブ演算ではなく)本物の関数呼び出しの場合も確認済み:
`checkA x && checkB y`は`case checkA x of {1 => checkB y; 0 => 0}`相当の`case`分岐に
展開され、短絡評価(`checkB`は該当する枝でのみ呼ばれる)は保たれたままクロージャは
一切構築されない。他の(`%inline`が付いていない)`Lazy`引数関数に同じ最適化が効くかは
未調査 -- 上の「Lambda lift で欠落する情報の保全」参照。

## memo
この項は人間が追加したものなので、後で整理して独立の項に括りだす事。
今は着手しないが将来的な展望を書き連ねる。この項は日本語で書かれるが
翻訳する必要はない。計画立案して項を独立した時に英語になっていればよい。
  

- **Performance: Closure Inlining and Immediate Expansion**
  `partial`呼び出しによるクロージャ生成とヒープ割り当てが、高階関数や型クラスの辞書使用時に頻発している。特に`List`操作や`mapAppend`のような高階関数において、`Boxed`なクロージャが多重生成されており、パフォーマンスを大きく阻害している。
  - 可能な限りコンパイル時にクロージャを特定し、直接呼び出しへとインライン展開するパスを実装する。
  - スコープ内で閉じている静的な定数クロージャは、最適化パスで完全にインライン化・削除を行う。

- **Performance: Higher-Order Function Specialization** -- 一般の高階関数
  (`mapAppend`等)の引数クロージャの割り当てコストは`RCConstClosure`の
  定数畳み込み(`rc2/doc/const-closure-fold.md`)で解消済み。呼び出し先
  自体をコード複製で型特化する方向は別途調査済み(コードサイズ膨張の
  ため見送り、詳細は同ドキュメント参照)。インターフェース辞書経由のメソッド呼び出し
  (`feed8`等)に限定した、より狭いスコープでの特殊化は
  「Performance: interface-dictionary method dispatch stays boxed even
  when the concrete instance is known」で実ベンチマークに基づき調査済み
  (複数パスにまたがる調整が必要と判明、未着手)。

- **`%export`: 対応型を拡大、生成ヘッダなしは未対応のまま**
  `%export`自体は実装済み(rc2は実ネイティブC-ABIラッパーを生成する唯一の
  バックエンド、詳細は`rc2/doc/export-support.md`と
  `rc2/tests/Test59Export/`(CFType形状ごとに1セクションのマージ済みテスト))。
  対応範囲はスカラー型(`Int`/`Int8`/.../`Double`/
  `Char`、`IO`/`IORes`)に加え、`Ptr`/`AnyPtr`、`GCPtr`/`GCAnyPtr`(引数のみ、戻り値は
  ファイナライザ発火タイミングの問題によりコンパイルエラー)、`Integer`(GMP、双方向)、
  `String`(戻り値、呼び出し側`free()`必須の所有権契約つき)、struct(ポインタ経由、
  `Ptr`と同じ仕組み)まで拡大。残っているスコープ外項目は2つ: (1) ラッパー自身の
  `.h`を生成しない(呼び出し側が`extern`宣言を手書きする必要がある)、(2) `Buffer`・
  ユーザー定義ADT(`List`/`Maybe`等)・関数/クロージャの引数/戻り値は非対応。詳細は
  `rc2/doc/export-support.md`参照。






