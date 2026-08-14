# Dual calling convention (`Compiler.RC2.DualABI`)

Implementation notes for rc2's dual (Boxed/native) function calling
convention -- letting a native representation cross an *ordinary*
function-call boundary, not just a self-tail-call loop's own `goto`
(that narrower case is `Compiler.RC2.Loop`'s own job, see
`doc/loop-conversion.md`). Written to let a future session (or a future
you) regain full context without re-deriving the design or
re-discovering the bugs already found and fixed here. Corresponds to
branch `dual-abi`; this document is a *living* one, updated as later
stages land -- see "Status" below for exactly what's implemented today
versus still planned.

(Japanese translation: `doc/ja/dual-abi.md`, kept in sync -- see
`CLAUDE.md`'s own doc index. Update both when editing this file.)

## The problem

Native type inference (`Compiler.RC2.Types`, `doc/native-type-inference.md`)
only ever applies *within* one function's own body -- every function
argument and return value is always Boxed, so a native-eligible value
gets boxed the moment it crosses a call boundary, and unboxed again the
moment the callee reads it. `Compiler.RC2.Loop`'s own native-shadow
promotion (`doc/loop-conversion.md`) already eliminates this round trip
for a *loop's own* carried parameters (the boundary between one
iteration and the next, inside a single C function) -- but an ordinary,
non-tail-recursive call between two different functions still pays the
full cost every time.

The canonical target is `fib`:

```idris
fib : Int -> Int
fib n = if n < 2 then n else fib (n - 1) + fib (n - 2)
```

Not tail-recursive (both recursive calls sit inside a `+`), so
`Compiler.RC2.Loop` never touches it. Every call boxes its argument on
the way in and its result on the way out, even though the *entire*
function body -- the comparison, the subtraction, the addition -- is
already native-Rep'd internally, per the existing native-type-inference
machinery, and stays that way regardless of where the recursive calls'
operand values originally came from.

## Design: worker/wrapper split (the GHC precedent)

For each function eligible for a native parameter and/or return value,
generate **two** C functions instead of one:

- **wrapper**: the function's own original, unchanged Boxed signature
  -- what every existing caller (closures, FFI, indirect dispatch, any
  call site not specifically rewritten) keeps using. Body is a thin
  shim: convert each eligible argument, call the worker, convert the
  result back if needed.
- **worker**: a freshly synthesised, internal-only function. Eligible
  parameters/return use their own native C type directly; everything
  else stays Boxed. Body is the *real* logic -- a copy of the original
  function's own body.

This is the classic worker/wrapper transformation (GHC uses the same
idea for strictness-driven unboxing). A direct, saturated call site
that already has (or only needs) the native representation can target
the worker directly, skipping the wrapper's own conversion shuffle
entirely -- **that rewrite is Stage 4's job, not yet implemented**; see
"Status" below.

### Why no whole-program fixed point is needed

The original plan sketch (see `TODO.md`'s pre-this-work "Dual calling
convention" entry) assumed this would need "escape analysis + a
fixed-point signature inference pass" -- classic interprocedural
strictness/unboxing analysis machinery. It turns out **both**
eligibility questions are answerable *locally*, one function at a time,
with no cross-function iteration:

- **A parameter's own eligibility** only depends on how *that
  function's own body* reads it: is it consistently used as a
  native-context `ROp`/`RCmpCase` operand? This is exactly
  `Compiler.RC2.Loop`'s own `nativeArgType` question, just asked about
  *every* top-level parameter instead of only loop-carried ones.
  Nothing about any other function is relevant.
- **A tail-position return value's own eligibility** comes from the
  *operator's own* type tag (`Types.opResultRep`), which never depends
  on where its operands came from. `fib(n-1) + fib(n-2)` is *already* a
  native-Rep'd `Add` today, regardless of whether `fib` itself is known
  to return natively -- the existing native-type-inference machinery
  decided that independently of any call-boundary question.

The one case this genuinely can't decide locally -- a *pure* tail-call
delegation with no arithmetic of its own (`g x = h x`, where `g`'s own
return eligibility really does depend on `h`'s) -- is a real, deliberate
v1 limitation, left ineligible rather than chasing the fixed point.
Given how the existing native-Rep tagging already propagates through
`ROp`/`RCmpCase` regardless of operand provenance, this narrower case is
believed to be comparatively rare in practice; revisit if profiling
ever shows otherwise.

## IR additions

### `MkRCFun`'s new shape (Stage 1)

```idris
MkRCFun : (args : List (Int, Rep)) -> (retRep : Rep) -> RCExp -> RCDef
```

Was `(args : List Int) -> RCExp -> RCDef` (implicitly all-Boxed).
Mirrors `RLoop`'s own "carries its own Reps" shape, at the
whole-function granularity instead of a single loop's. Every existing
construction site (`RC.idr`'s `normalizeDef`, `MutualLoop.idr`'s merged
function and per-member wrappers) supplies `RBoxed` uniformly, matching
the old implicit behaviour exactly -- landed as a pure, byte-identical
refactor (verified against `master`'s own compiler output, file by
file) *before* anything actually used the new shape, same discipline as
`Compiler.RC2.Loop`'s own Stage 1.

### `RAppNameRep` (Stage 3a)

```idris
RAppNameRep : FC -> Name -> (argReps : List Rep) -> (retRep : Rep) -> List RCLocal -> RCExp
```

A direct, saturated call to `name`'s own worker: `argReps`/`retRep`
describe how *this specific call* renders each argument and its own
result (`RNative ty` reads/produces a raw native value there, `RBoxed`
behaves like an ordinary `RAppName`). Never valid in a closure-building
position (`RUnderApp`, or a tail position `tryBuildClosureInto` would
otherwise defer into a closure) -- a closure's own argument slots can
only ever hold `IDRIS2RC2_Value *`, so a call needing a native argument
can never be represented that way. Only ever produced by
`Compiler.RC2.DualABI`, which runs strictly after `Compiler.RC2.Loop`
(see "Pipeline position" below); no earlier pass constructs or expects
to see one, and every earlier pass's own exhaustive `RCExp` matches
(`RC.idr`'s `annotate`, `Compiler.RC2.Loop`'s `renameRCExp`) got a
defensive pass-through case for it, same reasoning as their existing
`RLoop`/`RLoopContinue` cases.

## Pipeline position

```
RC (normalize+annotate) -> Reuse -> MutualLoop -> Loop -> DualABI -> Emit
```

`DualABI` runs *after* `Loop`, specifically so a self-tail-recursive
function's own parameter eligibility can be read straight off
`Compiler.RC2.Loop`'s own already-decided `RLoop.loopParams`, rather
than re-deriving it (see `paramEligibility` below). It also runs after
`MutualLoop`, and must explicitly exclude that pass's own synthesised
merged functions from worker synthesis -- see "A finding that changed
the plan" below.

## Stage 2: eligibility analysis (`paramEligibility`/`returnEligibility`)

Read-only; decides eligibility without synthesizing or rewriting
anything. Verified via a new `--directive dumpdualabi` debug dump
(mirrors `--directive dumprcexp`, writes `<outfile>.dualabi`) before any
of Stage 3's riskier rewriting was built on top -- catching design
mistakes here, where they're cheap to fix, rather than after they're
tangled up with ownership-stripping/codegen bugs.

### `paramEligibility : List Int -> RCExp -> List (Int, Maybe PrimType)`

For a body already `RLoop`-wrapped by `Compiler.RC2.Loop`: reads the
answer straight off that loop's own `loopParams`, positionally --
`RLoop`'s own `initial` always reads each loop param's starting value
from the *same-position* top-level argument, unconditionally, by
construction (`Compiler.RC2.Loop.applyLoop`'s own `initial = map RCLoc
argIds`), so `loopParams`'s own entries already line up with `argIds`
here, nothing further to check. Otherwise: `Compiler.RC2.Loop`'s own
`nativeArgType` (now `export`ed for this reuse), asked about every
top-level parameter instead of only loop-carried ones.

### `returnEligibility` / `tailValueReps`

`tailValueReps` walks every genuine (non-`RLoopContinue`) tail-position
value of a body, threading a `SortedMap Int Rep` of every local already
known to be native (seeded from `paramEligibility`'s own result, so a
bare tail return of an eligible parameter counts as native too --
extended further as the walk passes through `RLet`/`RLoop`'s own
bindings). A bare `RV`/`ROp`/`RPrimVal` gets its Rep read off directly;
a call, closure, constructor, extprim, erasure, or crash is *never*
native regardless of context (this is exactly what makes a pure
delegation chain ineligible, per the design note above).
`returnEligibility` is `Just ty` iff *every* such tail value agrees on
the same `ty`.

### Verification findings

Confirmed against the existing test/benchmark suite:

- `Main.fib` (`tests/BenchFib.idr`) -> `params=[Int] ret=Int` -- the
  marquee non-tail-recursive target this whole effort exists for.
- `Main.sumTo` (`tests/BenchLoop.idr`) -> `params=[Int, Int] ret=Int`,
  correctly read straight off `Compiler.RC2.Loop`'s own `RLoop`
  decision.
- `Main.countDown`/`Main.collatzLike` (`tests/Test9SelfTailLoop.idr`) ->
  correct *mixed* eligibility (one native parameter, one Boxed) within
  the same function.
- `Main.swapLoop`, and every `Compiler.RC2.MutualLoop`-produced
  per-member wrapper (`Main.isEvenM`/`isOddM`/`stepA`/`stepB` in
  `Test10MutualLoop.idr`) -> nothing eligible, correctly (no
  `ROp`/`RCmpCase` use of their own parameters at all -- a wrapper's own
  body is just a forwarding call to the merged function).

### A finding that changed Stage 3's own plan

`MutualLoop`'s own *merged* function (`{rc2_mutualLoop:N}`, as opposed
to its per-member wrappers above) **can** show real eligibility for a
shared slot some group member reads natively, even though a
*different*, smaller-arity member only ever supplies `RCNull` there --
confirmed directly against `Test10MutualLoop.idr`'s own `stepA`/`stepB`
group (`{rc2_mutualLoop:0}: params=["1:Boxed", "2:Boxed", "3:Int",
"4:Int"]`). This is the *exact* shape that already caused two real
crashes during `Compiler.RC2.Loop`'s own native-shadow promotion (see
`doc/loop-conversion.md`'s "Bugs found" #4) -- giving the merged
function's own *external* signature a native worker too would reopen
the same hazard at a different boundary. Unlike the wrappers (whose own
exclusion falls out for free -- nothing eligible to begin with), the
merged function needed an **explicit** exclusion:
`Compiler.RC2.DualABI`'s own `isMutualLoopMerged` (matching the
`MN "rc2_mutualLoop" _` name pattern `MutualLoop.idr`'s own
`freshName` mints) skips worker synthesis for it entirely.

## Stage 3a: worker synthesis (parameters only) + wrapper rewrite

`synthesizeWorker`, called from the whole-program `applyDualABI` for
every eligible, non-`MutualLoop`-merged function:

1. Mint a fresh worker name (`freshName`/`freshId`/`FreshId`, the same
   `Ref`-threaded-counter pattern `MutualLoop.idr` already uses).
2. `workerArgs`: each parameter promoted to `RNative ty` at the
   eligible positions, `RBoxed` everywhere else -- **reusing the
   original parameter's own id directly, no renaming needed at all**.
   This is a real simplification over `Compiler.RC2.Loop`'s own
   shadow-id trick: that mechanism needed a *fresh* id because it was
   retrofitting a new representation onto an *existing* C parameter
   within the *same* function (declaring `int64_t var_p` a second time,
   under a name already declared `IDRIS2RC2_Value *`, would be a C
   redeclaration error). A worker is a **brand-new** C function -- there
   is no existing declaration under that id to collide with, so the
   original id can just be redeclared directly, with its new (native)
   type, in the worker's own signature.
3. `workerBody`: the original body, verbatim, with the promoted
   parameters' now-stale ownership bookkeeping removed via
   `Compiler.RC2.Loop`'s own `stripOwnership` (now `export`ed) --
   called directly on the *original* parameter ids (not a renamed
   shadow set, since step 2 needed no renaming). `stripOwnership`'s own
   safety argument ("every value-reading occurrence of an id being
   stripped is already consistently native by this point") holds
   exactly the same way here as it does for `Compiler.RC2.Loop`'s own
   use -- see its own doc comment, updated to describe both call sites.
4. `workerDef`: `MkRCFun workerArgs retRep workerBody` -- **`retRep` is
   passed through unchanged from the original function** (always
   `RBoxed` today), never promoted, regardless of what
   `returnEligibility` found. This is Stage 3a's own deliberate scope
   limit -- see "Status" below for why.
5. `wrapperBody`: a single `RAppNameRep` call into the worker, one
   argument per original parameter, rendered per the worker's own
   decided `Rep` at that position.
6. `wrapperDef`: `MkRCFun args retRep wrapperBody` -- **unchanged**
   original signature and id, so every existing caller anywhere else in
   the program keeps working with zero changes.

### Emission (`Compiler.RC2.Emit`)

Two changes, both needed together for Stage 3a to produce working C at
all (confirmed the hard way -- see "Bugs found" below):

- **`createCFunctions`** (a function's own top-level C declaration) is
  now `Rep`-aware for its own parameter list: each parameter's own C
  type comes from its `Rep` (`nativeCType ty` for `RNative`/
  `RInlineNative`, `IDRIS2RC2_Value *` for `RBoxed`) instead of always
  the latter. `RepMap` (the incremental "which local has which `Rep`"
  table every *use* site consults) is now seeded with the function's
  own parameters up front, instead of starting empty -- without this,
  a native parameter's own *reads* within the body would still render
  Boxed (`repOfLocal`'s own default when nothing's registered), even
  though the C declaration itself was already correctly native. A
  worker needing more than `MaxExtractFunArgs` parameters, with at
  least one native, is an explicit `InternalError` for now (matches
  `RAppNameRep`'s own emission-side limit below -- see "Status").
- **`emitRC`'s new `RAppNameRep` case**: renders each argument per its
  own `Rep` (mirroring `tryEmitLoopContinue`'s own established
  per-position pattern), calls the worker directly, and handles the
  result per `retRep` -- only `RBoxed` is implemented so far (an
  `InternalError` otherwise), trampolined when not in tail position
  (matching an ordinary `RAppName`'s own behaviour exactly), returned
  bare when in tail position.

  **Why *not* deferring via a closure in tail position, unlike an
  ordinary `RAppName`, is safe here**: `tryBuildClosureInto` never
  intercepts `RAppNameRep` at all (a closure's argument slots can't
  hold a native value, so this call is always rendered as a genuine,
  immediate C call, tail position or not). For Stage 3a's *only*
  producer of this node -- a wrapper calling its own, freshly
  synthesised worker -- this is provably safe: it's always exactly one
  hop (the wrapper never calls anything else), never part of an
  unbounded recursive chain, so skipping the usual
  closure-deferral/trampoline dance here can't introduce unbounded C
  stack growth anywhere it wasn't already possible. **This safety
  argument is specific to Stage 3a's own narrow usage** (a
  fixed-topology, single-hop delegation) and needs to be revisited
  before Stage 4 starts rewriting *arbitrary* call sites throughout the
  whole program -- see "Open design question for Stage 4" below.

## Bugs found and fixed

1. **`createCFunctions` not yet `Rep`-aware when Stage 3a first landed.**
   The very first end-to-end build of a worker (`BenchFib.idr`'s own
   `fib`) failed to *compile the generated C*: the wrapper correctly
   unboxed its argument and called the worker with a raw `int64_t`, but
   the worker's own C signature still declared `IDRIS2RC2_Value *
   var_0` (Stage 1 had deliberately deferred making this side
   `Rep`-aware, see its own module note at the time -- "built together
   with whatever first produces a non-`RBoxed` value here"). Fixed by
   making `createCFunctions` consult each parameter's own `Rep` for its
   C declaration, and seeding `RepMap` with the function's own
   parameters up front (see "Emission" above) -- this was always the
   plan, just deliberately not built until something could actually
   exercise and verify it, per this project's own established
   discipline (`doc/loop-conversion.md`'s own "Bugs found" list is
   largely the history of what goes wrong when that discipline slips).
2. **`declareLoopParam`'s own NULL guard applied unconditionally, even
   when `initVal` was already native.** Found by the project's own
   full verification sweep (not just refc-suite -- this is exactly why
   that broader sweep is part of the standing methodology), in
   `Test1Basics.idr`'s own `Main.loop` and `Test9SelfTailLoop.idr`'s
   `countDown`/`collatzLike`: a `-Wall`-clean build failed with
   `comparison between pointer and integer` inside a synthesised
   worker. Root cause: a function that is *both* self-tail-recursive
   (already `RLoop`-wrapped, with `Compiler.RC2.Loop`'s own
   `declareLoopParam` unconditionally guarding its loop-entry unboxing
   against `MutualLoop`'s own `RCNull` padding -- see
   `doc/loop-conversion.md`'s "Bugs found" #4) *and* dual-ABI-eligible
   ends up with a worker whose own top-level parameter is *already*
   `RNative` (not `RBoxed`) by the time `Compiler.RC2.Loop`'s own
   `declareLoopParam` runs on it (`Compiler.RC2.Emit`'s `createCFunctions`
   registers it as such before the loop's own declarations run at
   all). `declareLoopParam`'s own NULL guard was written entirely
   under the assumption that `initVal` -- "always one of the enclosing
   function's own top-level (always-Boxed) args" -- can never itself
   already be native; `Compiler.RC2.DualABI`'s own worker synthesis is
   exactly the case that breaks that assumption. `rcVarToNativeC`
   itself already handled this correctly (an already-native local
   reads back as-is, no conversion emitted) -- but the *guard*
   wrapping it (`(initValName == NULL) ? 0 : (...)`) doesn't type-check
   when `initValName` is a bare `int64_t`, not a pointer. Fixed by
   checking `repOfLocal initVal` *first*: the guard (and the
   Boxed-value drop right after it) only ever apply when `initVal` is
   genuinely still `RBoxed`; an already-native `initVal` gets a plain,
   unguarded declaration instead. Re-verified: all four previously-
   failing files rebuild and, run against real `idris2 --cg refc`,
   still match byte-for-byte; full refc-suite (19/19) unaffected.

## Status

**Implemented and verified** (Stages 1, 2, 3a): the IR foundation, the
read-only eligibility analysis, and worker/wrapper synthesis for
parameters. `Main.fib` compiles to a wrapper (`Main_fib`, unchanged
Boxed signature) that unboxes its argument and calls a synthesised
worker (`rc2_dualABI_N`, `int64_t` parameter) doing the real recursive
work -- confirmed to compute the correct result (`832040` for `fib
30`), and the full refc-suite (19/19) plus the existing smoke-test/
benchmark matrix re-verified byte-for-byte/crash-free against `idris2
--cg refc`. **No performance change yet** -- nothing anywhere else in
the program calls a worker directly (every call still goes through the
unchanged wrapper, one extra thin layer deep), and no worker's own
return value is native yet either. This stage was deliberately scoped
to "get the worker/wrapper shape itself right, in isolation" before
building anything riskier on top -- see `doc/loop-conversion.md`'s own
precedent for why staging this way pays off.

**Not yet implemented**:

- **Stage 3b -- native returns.** Promote a worker's own `retRep` when
  `returnEligibility` found one, instead of forcing `RBoxed`
  unconditionally. Needs `Compiler.RC2.Emit`'s own `Sink`/`SinkReturn`
  to become `Rep`-aware (carrying the function's own decided `retRep`
  through `emitInto`'s dispatch down to the point a tail value is
  finally rendered), and a native-return counterpart to `emitRC`+
  `finalizeSink`'s existing (always-Boxed) path -- for a bare `RV` tail
  value, direct `rcVarToNativeC` (no drop needed, since
  `tailValueReps`'s own seeding guarantees anything it marked native
  really is, by construction); for an `ROp`/`RPrimVal`-shaped one,
  `emitNativeValue` plus the *same* drop-ordering care
  `declareNative`'s own doc comment describes (`doc/native-type-inference.md`'s
  "Bugs found" #4 is the exact mistake to avoid repeating: a native
  return's own pending Boxed-operand drops must happen *before* the
  `return` statement, via a temporary, never after -- there's no
  statement position after a `return` for a deferred drop to ever run).
  Deliberately split out from Stage 3a specifically because it touches
  some of `Emit.idr`'s highest-traffic, most-relied-upon code, and
  wanted its own isolated verification -- see the branch's own plan
  discussion.
- **Stage 4 -- call-site rewriting.** Walk every function's own body
  (not just tail positions -- an `RAppName` can appear anywhere, e.g.
  as an `ROp` operand) throughout the *whole* program, and rewrite
  every direct, saturated call targeting a function that now has a
  worker into `RAppNameRep`, with argument/result rendering chosen per
  what the *caller* already has on hand (or wants). This is where the
  actual performance win materialises -- e.g. `fib`'s own two
  recursive calls (currently still `Main_fib(idris2rc2_mkInt64(...))`,
  boxing on the way in and out every time) becoming direct
  `rc2_dualABI_0(...)` calls, native all the way through.

### Open design question for Stage 4

Stage 3a's own "always safe to skip closure-deferral, `RAppNameRep` is
never trampoline-deferred" argument (see "Emission" above) relied
entirely on every `RAppNameRep` call being a fixed, single-hop
delegation (wrapper -> its own worker, nothing else). Stage 4 will
introduce `RAppNameRep` calls at **arbitrary** call sites throughout the
program, including ones that used to be genuine tail-position
delegating calls `tryBuildClosureInto` would have deferred via a
closure (returned as a to-be-trampolined value, letting the *caller's*
own caller resolve it later, bounding C stack growth for an
otherwise-unknown-depth chain of tail calls that aren't self- or
mutually-recursive in a way `Compiler.RC2.Loop`/`Compiler.RC2.MutualLoop`
already convert to a `goto`). If Stage 4 ever rewrites *that* kind of
call site into a direct, non-deferred `RAppNameRep` call, it could
reintroduce unbounded C stack growth somewhere that was previously
protected. Before Stage 4 lands: work out exactly which call-site
shapes are safe to rewrite this way (a strong candidate: only rewrite
*non-tail-position* call sites at first, where there was never any
closure-deferral to begin with -- `emitRC`'s own existing `RAppName`
`NotInTailPosition` case *already* resolves the call immediately and
trampolines the result, so replacing it with a direct `RAppNameRep`
call changes representation, not this stack-depth property at all;
tail-position call sites, where deferral-avoidance *is* a real
behavioural change, may need to stay out of scope, or need their own
dedicated safety argument first).

## Files

- `rc2/src/Compiler/RC2/DualABI.idr` -- `paramEligibility`/
  `returnEligibility`/`tailValueReps` (Stage 2), `synthesizeWorker`/
  `applyDualABI`/`isMutualLoopMerged`/`FreshId` (Stage 3a),
  `describeEligibility`/`dumpDualABI` (the `--directive dumpdualabi`
  debug dump).
- `rc2/src/Compiler/RC2/RCExp.idr` -- `MkRCFun`'s new shape,
  `RAppNameRep`.
- `rc2/src/Compiler/RC2/Loop.idr` -- `nativeArgType`/`stripOwnership`
  now `export`ed for `Compiler.RC2.DualABI`'s own reuse; defensive
  `RAppNameRep` pass-through case in `renameRCExp`.
- `rc2/src/Compiler/RC2/RC.idr` -- `normalizeDef`/`annotateDef` updated
  for `MkRCFun`'s new shape; defensive `RAppNameRep` pass-through case
  in `annotate`.
- `rc2/src/Compiler/RC2/MutualLoop.idr` -- updated for `MkRCFun`'s new
  shape (merged function and per-member wrappers both still always
  `RBoxed`, unconditionally, by this pass's own design).
- `rc2/src/Compiler/RC2/Emit.idr` -- `createCFunctions` now `Rep`-aware
  for a function's own parameter declarations and `RepMap` seeding;
  `emitRC`'s new `RAppNameRep` case.
- `rc2/src/Compiler/RC2/Pretty.idr` -- `MkRCFun`'s new
  `args`/`retRep` rendering; `RAppNameRep`'s own `callRep` rendering.
- `rc2/src/Compiler/RC2/RC2.idr` -- `toRCDefs`'s own pipeline wiring
  (`applyDualABI` after `applyLoop`); `--directive dumpdualabi` wiring.

## Verification methodology

1. `cd rc2 && source ../env.sh && nix-shell -p idris2 gmp pkg-config --run 'idris2 --build rc2.ipkg'`
2. `cd tests/refc-suite && nix-shell -p gcc gmp pkg-config --run './run.sh'` -- expect 19/19.
3. `--directive dumpdualabi` (see Stage 2's own section above) on any
   candidate function is the fastest way to confirm eligibility
   *before* looking at generated C at all -- e.g. `grep "Main.fib"
   out.dualabi` should show `params=[Int] ret=Int`.
4. `tests/BenchFib.idr` is the canonical Stage 3a smoke test: `fib 30`
   must still print `832040`; `grep -n "^IDRIS2RC2_Value
   \*rc2_dualABI" build/exec/*.c` confirms a worker actually got
   synthesised, and reading its own C body directly confirms the
   promoted parameter is declared with its native C type and the
   original's own recursive calls still target the *wrapper*
   (`Main_fib`, not the worker directly) -- that specific detail is
   what confirms Stage 4's own call-site rewriting hasn't accidentally
   started firing early.
5. Full `tests/Test*.idr`/`tests/Bench*.idr` suite, diffed against real
   `idris2 --cg refc` output, same as every other stage in this
   project -- Stage 3a is supposed to be purely a structural/codegen
   change, so *every* test must still match byte-for-byte, with zero
   observable behaviour difference.
