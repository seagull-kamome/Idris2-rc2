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

## Correctness: `List.(++)` leaks memory on repeated `IORef` append

Found incidentally while testing `Channel`'s `channelPut`
(`rc2/doc/concurrency.md`'s Concurrency work, commit `05c5c78`), but
reproduces on a single-threaded, non-concurrent program: repeatedly
`modifyIORef`/`writeIORef`-appending to a `List` held in an `IORef`
(three appends was enough to trigger it in `TestConcurrency.idr`) leaks
memory via `idris2rc2_newConstructor`, on the order of 40-280 bytes per
run. Unrelated to concurrency itself -- the `channelPut` test just
happened to be the first thing in this codebase to exercise
`List.(++)` (`Prelude.Types`'s `reverseOnto`/`tailRecAppend`) this way.
Not investigated further and not fixed; recorded here as found, not
root-caused.

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

## Correctness: `--directive noreuse` corrupts the heap on several smoke tests

`rc2/tests/verify.sh --directive noreuse` (see its own "--directive"
option, added to let a session compare an optimisation pass on vs.
off) surfaces a real heap corruption in 11 of 17 smoke tests
(`Test1Basics`, `Test2Recursion`, `Test3Data`, `Test4Closures`,
`Test5FFIStrings`, `Test7CastMatrix`, `Test8EmptyCon`,
`Test9SelfTailLoop`, `Test10MutualLoop`, `Test12ConAltNative`,
`Test13NativeArgChain`) -- `malloc(): unaligned tcache chunk detected`
at runtime, not a compile error. `--directive noconaltnative` alone is
unaffected (all 17 pass); the corruption is specific to disabling
`Compiler.RC2.Reuse` itself, not something `ConAltNative` depends on.

Not investigated further yet -- likely a later pass
(`ConAltNative`/`MutualLoop`/`Loop`/`DualABI`, or `Emit` itself)
implicitly relies on `Compiler.RC2.Reuse` having already run (e.g.
assuming every `RCon`'s own `reuseFrom` field, or the absence of a
dangling `RReuseOffer`/`RReleaseReuse`, in a way that's silently wrong
when `Reuse` is skipped) rather than being a genuinely independent,
disableable stage the way `--directive noconaltnative`/`noloop`/etc.
are. Doesn't affect the default pipeline (`Reuse` always runs unless
explicitly disabled), so it's not a correctness bug in what ships --
only surfaces via this debug flag -- but worth root-causing before
trusting `--directive noreuse` for any future performance comparison.

Repro: `cd rc2/tests && ./verify.sh --skip-build --no-valgrind --directive noreuse`.

## Correctness: `CFString`'s hardcoded `char *` return type collides with `-Werror` on a `const`-returning C function

Also found via the libcurl experiment above: `curl_easy_strerror`
returns `const char *`. `Compiler/RC2/EmitUtil.idr`'s own
`cTypeOfCFType CFString = "char *"` (no `const`) makes the generated
call site `char * retVal = curl_easy_strerror(...)`, which GCC flags as
`-Wdiscarded-qualifiers` -- and `CC.idr`'s own `-Werror` (both the
`-c` and link steps) turns that into a hard build failure, not just a
warning.

Not rc2-specific either: upstream RefC's own `RefC.idr` has the
byte-for-byte identical `cTypeOfCFType CFString = "char *"`, so any
`const char *`-returning C function hits the same wall there too. No
existing rc2/RefC test happens to bind one. Two possible fixes if this
is ever worth pursuing: (a) generate `const char *` for `CFString`
foreign *return* types specifically (would need extractValue/packCFType
to know a call's own foreign-return position, not just the CFType
itself), or (b) document the limitation and let callers work around it
with a thin non-const C wrapper. Not investigated further; no
regression test exists for it yet.

## `Integer` (`CFInteger`) has no `%foreign` codegen support at all

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
or return type crashes rc2's own codegen:
`ERROR: INTERNAL ERROR: Unknown FFI type in rc2 backend: Integer`.

Root cause: `CFInteger` is a real constructor of `CompileExpr.idr`'s
own `CFType` (`Core/CompileExpr.idr`, alongside `CFInt`/`CFString`/
etc.), but `Compiler.RC2.EmitUtil`'s `cTypeOfCFType`/`extractValue`/
`packCFType` have no case for it at all -- it falls straight through
to the generic `idris_crash "Unknown FFI type"` fallback. **Not
rc2-specific**: confirmed the identical crash (`Unknown FFI type in C
backend: Integer`) against upstream `idris2 --cg refc` with the same
repro -- RefC's own `RefC.idr` has the exact same gap. Presumably
never hit before because `Integer`-typed `%foreign` declarations are
rare (arbitrary-precision values don't map onto a fixed-width C
parameter without a marshalling decision -- `Integer` `%foreign`
returns elsewhere in this codebase, e.g. `Network.Curl`'s `off_t`
question in a sibling project's own TODO.md, deliberately avoid this
by using `Int`/`String` instead).

Not investigated further (found via unrelated library-compatibility
exploration, not pursued): would need a representation decision before
implementing (`extractValue`'s own C-side type -- a fixed-width
integer truncates for anything beyond that width; a GMP `mpz_t`-backed
representation would need its own boxing/unboxing shim, mirroring how
`IDRIS2RC2_Integer` already works for the *ordinary* (non-FFI) `Integer`
representation inside rc2's own runtime, `support/rc2/memory.c`'s
`idris2rc2_mkInteger`). Revisit if a concrete library/binding actually
needs an `Integer`-typed `%foreign` argument or return badly enough to
justify it -- `idris2-array`'s own buffer primitives (the case that
surfaced this) were not pursued further, since fixing them would also
require a separate upstream fix or a local `%foreign_impl`-based
patch, and the underlying `idris2-json` build was abandoned instead.

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

## Scope: FFI worker synthesis (Stage 3c) keeps its own 8-argument limit

`Compiler.RC2.DualABI`'s ordinary-function worker synthesis (Stage 3a,
`synthesizeIfEligible`/`synthesizeWorker`) no longer excludes functions
with more than `Compiler.RC2.EmitUtil.MaxExtractFunArgs` (8) parameters --
a dual-ABI *worker* is only ever reached via a direct, statically-named
`RAppNameRep` call, never stored in a `Closure`, so it doesn't need to
satisfy `support/rc2/runtime.c`'s closure-dispatch function-pointer
convention (`IDRIS2RC2_FUN0`..`FUN8`/`FUNSTAR`) that convention exists
for -- `MkRCFun`'s new `isWorker` field lets `Compiler.RC2.Emit`'s
`createCFunctions` skip the width-based `var_arglist[]` declaration
fallback specifically for workers, regardless of argument count. See
`rc2/tests/Test33WideDualABIWorker.idr` for the regression test (a
10-parameter function, 9 native-eligible `Int`s + 1 `Boxed` `String`,
mirroring a real bug report where an externally-sourced package's
lambda-lifted internal helper hit exactly this shape).

Stage 3c's own separate FFI worker synthesis (`ffiWorkerTable`,
`DualABI.idr`'s `length fargs > MaxExtractFunArgs` exclusion) was left
untouched -- a structurally distinct code path (`MkRCForeign`, not
`MkRCFun`) not investigated as part of this change. A `%foreign`
declaration with more than 8 parameters still gets no worker
synthesized at all, unconditionally. Plausibly the same "the callee
side never needs the closure-dispatch convention" argument applies
there too (an FFI worker is also only ever called directly), but this
hasn't been checked. Not currently planned; revisit if a real
`%foreign` binding this wide with native-eligible parameters ever
shows up.

## yet another hope
この項は人間が追加したものなので、後で整理して独立の項に括りだす事。
今は着手しないが将来的な展望を書き連ねる。この項は日本語で書かれるが
翻訳する必要はない。計画立案して項を独立した時に英語になっていればよい。

- Cのレベルで無駄な代入が相変わらず発生している。Cコードの可読性を向上させたい
- カスタムメモリアロケータに対応したい。例えばpythonに組み込む時にpython側
  のアロケータを使えれば効率化につながるのでは？
- slabの様にfree-list風に高速割り当てできる固定アロケータを使えるようにしたい。
- マルチスレッド対応は別にネイティブスレッドを使える必要はないはず。
  ランタイム提供するワーカースレッドを使ったdotnetのTask風機能は比較的簡単に
  作れるのでは？
- 変数がタグ付きポインタ化された32ビット未満整数の場合、ネイティブ化されていなくても
  dup/dropを省略できる。
- 比較演算子の融合はinline展開の後にやらないと効果が限定されてしまうのでは？
- libgc板のランタイム。dup/drop/freeをCマクロで消去してしまい、mallocを単純に差し替える
  だけでlibgc対応できるのでは？
- 短い文字列をタグ付きポインタに押し込む
- **Performance: Closure Inlining and Immediate Expansion**
  `partial`呼び出しによるクロージャ生成とヒープ割り当てが、高階関数や型クラスの辞書使用時に頻発している。特に`List`操作や`mapAppend`のような高階関数において、`Boxed`なクロージャが多重生成されており、パフォーマンスを大きく阻害している。
  - 可能な限りコンパイル時にクロージャを特定し、直接呼び出しへとインライン展開するパスを実装する。
  - スコープ内で閉じている静的な定数クロージャは、最適化パスで完全にインライン化・削除を行う。

- **Performance: Higher-Order Function Specialization**
  `mapAppend`のような汎用的な高階関数は、すべて`Boxed`な値を引数に取るため、頻繁なポインタ参照とヒープ割り当てが発生している。
  - 特定の型（例：`List Double`）に対して高階関数が呼び出されている場合、コンパイル時に型特化した関数を生成する（テンプレート化/マングリング）。
  - 特化により、`Boxed`なCONSセル走査を、ネイティブな配列走査へと置き換え、参照カウント操作を削減する。






