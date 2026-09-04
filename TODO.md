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
Boxed-context read now, instead of `EmitUtil.idr`'s `rcVarToBoxedC`
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
`EmitUtil.boxedConstExpr` dedup bug it exposed: see
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

`String`'s primitives are Unicode-codepoint-, not byte-, indexed,
matching Idris2's own Chez backend -- see `rc2/README.md`'s "Deliberate
differences from upstream RefC" section for that fix.

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
  バックエンド、詳細は`rc2/doc/export-support.md`と`rc2/tests/Test59ExportScalar.idr`
  〜`Test64ExportString.idr`)。対応範囲はスカラー型(`Int`/`Int8`/.../`Double`/
  `Char`、`IO`/`IORes`)に加え、`Ptr`/`AnyPtr`、`GCPtr`/`GCAnyPtr`(引数のみ、戻り値は
  ファイナライザ発火タイミングの問題によりコンパイルエラー)、`Integer`(GMP、双方向)、
  `String`(戻り値、呼び出し側`free()`必須の所有権契約つき)、struct(ポインタ経由、
  `Ptr`と同じ仕組み)まで拡大。残っているスコープ外項目は2つ: (1) ラッパー自身の
  `.h`を生成しない(呼び出し側が`extern`宣言を手書きする必要がある)、(2) `Buffer`・
  ユーザー定義ADT(`List`/`Maybe`等)・関数/クロージャの引数/戻り値は非対応。詳細は
  `rc2/doc/export-support.md`参照。






