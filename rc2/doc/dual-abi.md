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

(Japanese translation: `doc/ja/dual-abi.md`, updated only on request --
this English original is the one kept current on every edit.)

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
entirely -- **that rewrite is Stage 4's job** (implemented -- see
"Stage 4" and "Status" below).

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
Lifted (Compiler.LambdaLift)
  -> Compiler.RC2.Inline          (whole-program inlining, Lifted -> Lifted)
  -> Compiler.RC2.RC.normalize    (Phase 1: ANF-style, native type inference)
  -> Compiler.RC2.RC.annotate     (Phase 2: ownership -- RDup/RDrop/RFree)
  -> Compiler.RC2.Reuse           (constructor-reuse-in-place)
  -> Compiler.RC2.ConAltNative    (native-shadow field caching)
  -> Compiler.RC2.MutualLoop      (mutual tail recursion -> one merged function)
  -> Compiler.RC2.Loop            (self-tail-call -> RLoop/RLoopContinue,
                                    plus native-shadow promotion)
  -> Compiler.RC2.DualABI         (worker/wrapper synthesis, call-site rewrite -- this module)
  -> Compiler.RC2.Emit            (purely mechanical RCExp -> C)
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
(mirrors `--directive dumprcexpr`, writes `<outfile>.dualabi`) before any
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
  `Test9SelfTailLoop.idr`) -> nothing eligible, correctly (no
  `ROp`/`RCmpCase` use of their own parameters at all -- a wrapper's own
  body is just a forwarding call to the merged function).

### A finding that changed Stage 3's own plan

`MutualLoop`'s own *merged* function (`{rc2_mutualLoop:N}`, as opposed
to its per-member wrappers above) **can** show real eligibility for a
shared slot some group member reads natively, even though a
*different*, smaller-arity member only ever supplies `RCNull` there --
confirmed directly against `Test9SelfTailLoop.idr`'s own `stepA`/`stepB`
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
   `Ref`-threaded-counter pattern `MutualLoop.idr` already uses) --
   `idris2rc2_worker_` plus the *original* function's own mangled C
   name (`Compiler.RC2.EmitUtil`'s own `cName`, `export`ed for this
   reuse -- the exact same mangling the wrapper's own unchanged C name
   already uses) plus a disambiguating counter, e.g. `Main.fib`'s own
   worker is `idris2rc2_worker_Main_fib_0` -- deliberately legible on
   sight, both as *generated* (matching the project's own established
   `idris2rc2_`-prefix convention for every runtime-owned C symbol) and
   as *visibly this specific original function's own worker*, rather
   than the original, opaque `rc2_dualABI_N` global counter.
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
  fixed-topology, single-hop delegation) and does *not* automatically
  extend to Stage 4's own, much broader call-site rewriting -- see
  "Stage 4"'s own "Scope: non-tail-position calls only, permanently"
  below for how that stage resolved it (by simply never touching a
  tail-position call site at all, rather than trying to prove this
  same argument for arbitrary ones).

## Stage 3b: native returns

Promotes a worker's own `retRep` to `RNative ty` when `returnEligibility`
found one (`synthesizeWorker` now takes `retEligible : Maybe PrimType`
separately from the wrapper's own `wrapperRetRep`, which stays exactly
what the original function's `retRep` already was -- see
`Compiler.RC2.DualABI`'s own updated doc comment). `applyDualABI`'s own
"should this function even get a worker" test widened from "at least
one eligible parameter" to "at least one eligible parameter *or* an
eligible return" -- a function with zero eligible parameters but a
native-eligible return (e.g. a closed computation with no numeric
parameter to promote) is a real, if narrow, case this now covers too.
`isMutualLoopMerged`'s own blanket exclusion already covered the
return side for free -- it skips worker synthesis for a merged
function entirely, regardless of which side turned out eligible.

Landed as its own stage, after Stage 3a, specifically because it
touches `Sink`/`SinkReturn` (`Compiler.RC2.EmitUtil`) machinery
threaded pervasively through `Compiler.RC2.Emit`'s own emission
engine -- exactly the "materially riskier change to some of that module's
highest-traffic code" flagged when Stage 3a was scoped down to
parameters only.

### Design: one field on `Sink`, one dispatch point

The actual change turned out smaller than the risk assessment implied,
because of how centralised `Emit.idr`'s own control flow already was:
every branching construct (`RCmpCase`/`RConCase`/`RConstCase`/`RLoop`)
already threads the *same* `Sink` down to each of its own branches via
recursive `emitInto` calls, all the way down to the one fallback arm
that handles a genuine leaf expression. So:

- **`Sink`'s own `SinkReturn` constructor gains a `Rep` field**
  (`SinkReturn Rep`, was `SinkReturn` with no payload) -- the enclosing
  function's own `retRep`, threaded in once by `createCFunctions`
  (`emitInto EmptyFC (SinkReturn retRep) InTailPosition body`, was a
  bare `SinkReturn`).
- **`resolveSink`/`finalizeSink`/`chainsWithElse`/`buildClosureIntoSink`**
  needed no *logic* changes at all, only pattern-widening to accept the
  new field (`SinkReturn _`) -- none of their own behaviour depends on
  *which* Rep a return carries, only on the fact that it's a `return`
  rather than a variable assignment.
- **`emitInto`'s own single fallback arm** (the one place every genuine
  leaf value -- `RV`/`ROp`/`RPrimVal`/etc. -- ultimately lands) is the
  *only* place that actually inspects the Rep: `SinkReturn (RNative
  ty)`/`SinkReturn (RInlineNative ty)` routes to a new `emitNativeReturn`
  instead of the ordinary `emitRC`-then-`finalizeSink` pair; every other
  `Sink` is unaffected.

Because every branching construct already just re-threads the same
`Sink` value it was given, this one dispatch point is enough to make a
loop's own exit value, or a value returned from inside an arbitrarily
nested `if`/`switch` chain, render natively too -- with zero changes to
`emitCmpCaseInto`/`emitConCaseInto`/`emitConstCaseInto`/`emitLoopInto`/
`branchBody` themselves. `Main.sumTo` (loop-carried native parameters
*and* a native return, together) exercises exactly this path: the
loop's own exit (`if (tmp_3 == 0) { return var_4; }`) renders through
the very same fallback arm as `Main.fib`'s own (non-loop) tail
positions do.

### `emitNativeReturn`: the "no statement position after `return`" problem

`declareNative` (an `RLet`'s own native binding) already had to solve a
closely related problem: `emitNativeValue`'s own pending Boxed-operand
drop(s) (see its own doc comment) must run *after* the statement that
reads the value, never before -- but for an `RLet`, "after" is easy,
there's always a next statement in the same block. A `return` has no
such "after" -- control leaves the function immediately, so a drop
placed following a bare `return valStr;` would simply never execute.

`emitNativeReturn` mirrors `declareNative`'s own two-step shape
(materialise the value, *then* discharge pending drops) but only pays
for the extra scratch variable when there's actually a pending drop to
sequence around:

```idris
emitNativeReturn fc ty value = do
    (valStr, pending) <- emitNativeValue ty value
    case pending of
         [] => emit fc "return \{valStr};"
         _  => do
             tmp <- getNewVarThatWillNotBeFreedAtEndOfBlock
             emit fc "\{nativeCType ty} \{tmp} = \{valStr};"
             removeVars $ map varName pending
             emit fc "return \{tmp};"
```

The scratch variable reuses the existing `tmp_N` naming
(`getNewVarThatWillNotBeFreedAtEndOfBlock`, already used by
`makeClosure` for the same "must survive past its own declaring
statement" need) rather than the `var_N` numbering space real `RCLoc`
ids own -- `declareNative` gets away with `var_N` because it's
declaring a genuine, tree-numbered local; this is a synthetic,
emission-only temporary with no id of its own in the `RCExp` tree, so
reusing `var_N` here would risk colliding with a real local.

`Main.fib`'s own worker is the canonical example of the non-trivial
path (both recursive calls' own Boxed results need dropping *after*
the addition reads them):

```c
int64_t tmp_8 = (idris2rc2_to_i64(var_3) + idris2rc2_to_i64(var_5));
idris2rc2_drop(var_3);
idris2rc2_drop(var_5);
return tmp_8;
```

and its own base case (a bare parameter returned directly, `if (n < 2)
then n else ...`) is the trivial path -- no pending drop at all, so no
scratch variable either:

```c
if (tmp_7 == UINT8_C(1)) {
    idris2rc2_drop(var_1);
    return var_0;
}
```

### `emitNativeValue` gains a bare `RV` case

`emitNativeValue` previously only had to handle what Phase 1's own ANF
normalisation could ever hand an `RLet`'s tail: an `ROp`, an
`RPrimVal`, or one of the transparent wrapper nodes (`RLet`/`RDup`/
`RDrop`/`RFree`/`RReleaseReuse`) -- never a bare `RV`, since a
"just copy this other local" `RLet` binding never arises that way. But
`Compiler.RC2.DualABI`'s own `tailValueReps` (Stage 2) always allowed a
bare tail-position `RV` to count as native (a parameter, or an
already-native intermediate, returned unchanged) -- and Stage 3b is the
first thing that actually reaches this case at emission time (`Main.fib`'s
own `if n < 2 then n else ...` base case, above). Added directly:

```idris
emitNativeValue ty (RV fc v) = do
    valStr <- rcVarToNativeC ty v
    pure (valStr, [])
```

No pending drop at all -- unlike an `ROp`'s own operands, `v` here is
already known native by construction (`tailValueReps`'s own seeding
guarantees it), so there's no Boxed read to clean up after.

### `RAppNameRep`'s own native `retRep` case

A worker's own return being promoted to native means the *wrapper's*
call into it (`RAppNameRep`, Stage 3a) can now genuinely have a
non-`RBoxed` `retRep` too -- previously an `InternalError` ("not yet
implemented"). `emitRC`'s own contract for this node (as for every
other case in that function) is "always render a Boxed expression
string" -- `RBoxed` behaves exactly as before (trampolined off tail
position, bare in tail position); `RNative`/`RInlineNative` means `call`
itself is already the worker's own raw native result, so it's boxed
directly via `nativeMk ty call`, unconditionally regardless of tail
position -- a native value can never itself be "a trampoline still
awaiting resolution" (that's a Boxed-representation-only concept: a
tagged heap pointer that might encode an unresolved continuation), so
there's nothing to defer either way. `Main.fib`'s own wrapper is the
concrete example:

```c
IDRIS2RC2_Value *Main_fib(IDRIS2RC2_Value * var_0)
{
    return idris2rc2_mkInt64(idris2rc2_worker_Main_fib_0(idris2rc2_to_i64(var_0)));
}
```

Only this direction (rendering a native worker's own result as Boxed,
for a wrapper's always-Boxed tail value) is what `emitAppNameRepInto`
itself does -- at the time Stage 3b landed, that was still the *only*
producer of this node (`Compiler.RC2.DualABI`'s own wrapper body,
always feeding a `SinkReturn RBoxed`). A caller wanting `RAppNameRep`'s
own result rendered *natively* instead (skipping the boxing) turned
out to be Stage 4's own concern after all -- not by changing
`emitAppNameRepInto`, but via a separate, dedicated `RAppNameRep` case
on `emitNativeValue` (see Stage 4's own "The promotion" section below)
for the one new shape Stage 4 introduces: an `RLet` whose own call
result is promoted straight to native, never boxed at all.

### `createCFunctions`'s own return-type declaration

The one remaining piece: the C function declaration itself
(`IDRIS2RC2_Value *\{cName ...}`, unconditional) now derives its return
type from `retRep`, mirroring `declareParam`'s own existing per-argument
logic:

```idris
let retTypeStr : String = case retRep of
                                RBoxed => "IDRIS2RC2_Value *"
                                RNative ty => nativeCType ty ++ " "
                                RInlineNative ty => nativeCType ty ++ " "
let fn = "\{retTypeStr}\{cName !(getFullName n)}" ++ ...
```

`Main.fib`'s own worker forward-declares as `int64_t idris2rc2_worker_Main_fib_0(int64_t
var_0);` -- confirmed by reading the generated C directly, same
verification discipline as every other stage.

## Stage 4: call-site rewriting

Where the actual performance win materialises. Landed as one combined
stage rather than split further (unlike 3a/3b) -- the "rewrite the
call" half reuses already-verified emission machinery
(`emitAppNameRepInto` already boxes a native result on demand) with
essentially no new risk, and the "promote the enclosing `RLet`" half
is what makes the rewrite actually pay off; doing only the first half
would have left every call boxing its own result only to immediately
unbox it again, an underwhelming win not worth its own separate stage.

### Scope: non-tail-position calls only, permanently

Only a direct, saturated, **non-tail-position** call to an *ordinary*
RC2 function worker gets redirected to it. Tail-position calls to such
a worker are a *deliberate, permanent* scope boundary, not a later
stage: they're currently rendered via `tryBuildClosureInto`'s own
closure-deferral (a boxed, trampolined value, letting the *caller's own
caller* resolve it later -- bounds C stack growth for an
otherwise-unknown-depth chain of tail calls that aren't self-/
mutually-recursive in a way `Compiler.RC2.Loop`/`Compiler.RC2.MutualLoop`
already convert to a `goto`). Rewriting such a call into a direct,
non-deferred `RAppNameRep` call could reintroduce that unbounded
growth, and telling *which* tail-position call sites are safe to
rewrite this way would need real interprocedural analysis -- exactly
the whole-program fixed point this entire effort has otherwise avoided
needing (the same reason `returnEligibility`, in Stage 2, already
leaves a *pure* tail-call delegation ineligible rather than chasing
it).

A tail-position call to an **FFI worker** (Stage 3c, below) is the one
exception to this boundary -- see "Stage 4b: tail-position FFI calls"
after Stage 5 for why a `%foreign` callee doesn't carry the same risk.

### The worker table

`workerTable` recovers "which functions got a worker, and what its own
`(workerName, argReps, retRep)` is" by scanning the post-`applyDualABI`
def list for the exact shape `synthesizeWorker` always produces for a
wrapper: `MkRCFun _ _ (RAppNameRep _ workerName argReps retRep _ _)`,
nothing else in its own body. No separate table needs threading out of
`applyDualABI` itself.

### The rewrite: `applyCallSiteRewriteBody`

Walks every definition's own body (wrapper, worker, or untouched
function -- all rewritten by exactly the same logic, nothing here needs
to know which of the three a given definition is), threading a
`SortedMap Int Rep` of locally-known Reps (same seeding/extension
`paramEligibility`/`tailValueReps` already use) and a `Bool` tracking
whether the current point is genuinely the *whole function's* own tail
position -- `True` only at the top-level entry point, and everywhere
`RLet`'s own `body`, every branching construct's own branches, and
every wrapper node's own `cont` thread it straight through unchanged.

The one genuine subtlety: an `RLet`'s own *value* is not always the
flat leaf (`ROp`/`RAppName`/`RCon`/etc.) it might look like. Phase 1's
own ANF normalisation of a call *argument* expression nests a further
`RLet` **inside** the outer one's own value --

```
let v3 = (let v4 = n - 1 in fib v4) in
let v5 = (let v6 = n - 2 in fib v6) in
v3 + v5
```

-- so the actual call can sit arbitrarily deep in a chain of further
`RLet`s, never directly as `value` itself. The `RLet` clause handles
this by *recursing* into `value` first (in non-tail mode, so whatever
`RAppName` sits at *its own* ultimate tail -- reached via this same
function's own catch-all, the only clause that actually rewrites
anything -- gets rewritten too), then inspecting the rewritten
`value1`'s own `ultimateTail` (peeling through that same nested-`RLet`
shape) to decide whether the *outer* `RLet` itself -- `v3`, `v5` above,
not `v4`/`v6` -- is a promotion candidate.

`postDropFor` needs no liveness analysis of its own to decide which
rewritten arguments need an explicit drop: `Compiler.RC2.RC`'s own
`annotate` already decided, for the *original* (still-`RAppName`) call
being replaced, that passing a Boxed argument to a call consumes
exactly one reference (dup'ing beforehand if that argument's own local
is still needed after this point) -- reading it natively instead and
dropping it right here pays the exact same net cost, so whatever
`annotate` already arranged around the call site still balances
correctly either way.

### The promotion: `nativePromotionFor`

Reuses `Compiler.RC2.Loop`'s own `nativeArgTypes` (now `export`ed
alongside `nativeArgType`) directly -- the same question it already
asks about a whole function's own top-level parameter, just asked
about an `RLet`-bound worker-call result instead: does the rest of
this let's own scope read it as a native-context operand,
consistently, at the worker's own `retRep`? When it finds one,
`stripOwnership` (reused a third time, no id renaming needed here
either -- a fresh `RLet` binding, not retrofitting onto an
already-declared C variable) removes whatever stale Boxed-lifetime
bookkeeping `annotate` attached to it back when it assumed an ordinary
Boxed local. Any *other*, still-Boxed-context use of the same local
elsewhere (e.g. stored into a constructor field) keeps working
regardless of promotion, via `rcVarToBoxedC`'s own on-demand reboxing
of a native value -- a fresh allocation instead of sharing the one
this call *used* to produce, invisible to any Idris-level program
(scalars have no observable identity).

`fib`'s own worker is the concrete before/after:

```c
// before Stage 4
IDRIS2RC2_Value * var_3 = idris2rc2_trampoline(Main_fib(idris2rc2_mkInt64(var_4)));
IDRIS2RC2_Value * var_5 = idris2rc2_trampoline(Main_fib(idris2rc2_mkInt64(var_6)));
int64_t tmp_9 = (idris2rc2_to_i64(var_3) + idris2rc2_to_i64(var_5));

// after Stage 4
int64_t var_3 = idris2rc2_worker_Main_fib_0(var_4);
int64_t var_5 = idris2rc2_worker_Main_fib_0(var_6);
return (var_3 + var_5);
```

No boxing, no unboxing, no dup/drop at all for either recursive call's
own argument or result -- the whole computation stays in `int64_t`
from the worker's own entry to its own `return`.

### Extending the promotion to call-argument chains: `callArgNativeReads`

`nativeArgTypes`/`bareTailNativeReads` only ever look for `var` read as
an `ROp`/`RCmpCase` operand, or at a bare tail. They miss a third
shape: `var` fed straight into *another* worker's own native argument
position (`ffiCall2 (ffiCall1 x) y`-shaped chains, not just
`fib(n-1) + fib(n-2)`-shaped ones) -- increasingly common once Stage 5
makes FFI calls cheap leaf nodes to chain together. `callArgNativeReads`
closes that gap: it walks `body` the same way `nativeArgTypes` does,
and for every bare `RAppName` it finds (`body` is always the
*not-yet-Stage-4-rewritten* subtree at the point this runs, so a call
still looks like this, never yet an `RAppNameRep`), looks `var`'s own
occurrence up against that callee's own `workers` table entry -- an
occurrence at a position the callee's own `argReps` says is
`RNative`/`RInlineNative` counts, one at a `RBoxed` position doesn't.
`nativePromotionFor` just unions this in as a third source alongside
the other two. Whether the target's own `workers` entry is tagged
`True` (FFI, Stage 4b) or `False` (ordinary) doesn't matter here --
Stage 4's *non-tail* clause already rewrites through either kind
unconditionally, and an occurrence that instead sits in a genuinely
tail-position call to an ordinary worker (left deferred via a closure)
still renders correctly either way: closure slots only ever hold
`IDRIS2RC2_Value *`, so `var` is reboxed on the way in exactly like any
other still-Boxed-context use -- the same "reboxed on demand, still
correct" reasoning `nativePromotionFor` itself already relies on.

`rc2/tests/Test13NativeArgChain.idr`'s own `chainCallArg`/`addAbsCallArg`
(formerly a separate `Test56NativeCallArgChain.idr`, merged in) is the
concrete before/after (`addAbsCallArg`'s own body calls an FFI declaration, so
it's never `Compiler.RC2.Inline`-eligible, and its first parameter is
native only via the nested-`RLet`-body fix this same file's own `chain`
covers -- both deliberately chosen so the call itself, and a genuinely
native target argument, both survive to Stage 4 intact):

```c
// before this extension
IDRIS2RC2_Value * var_3 = (IDRIS2RC2_Value*)idris2rc2_mkInt64(abs(idris2rc2_to_i64(var_0)));
int64_t var_2 = idris2rc2_worker_Main_addAbsCallArg_1(var_3, var_1);

// after
int64_t var_3 = abs(idris2rc2_to_i64(var_0));
int64_t var_2 = idris2rc2_worker_Main_addAbsCallArg_1(var_3, var_1);
```

`var_3` no longer round-trips through `IDRIS2RC2_Value *` at all between
the two calls. Verified leak-free via `valgrind` (registered in
`verify.sh`'s `LEAK_SENSITIVE_TESTS`), and against `rc2/tests/verify.sh`
as a whole: 90 passed, 0 known, 0 failed.

## Stage 3c: FFI worker synthesis

Extends the same worker/wrapper idea across a `%foreign` call boundary
-- a `MkRCForeign` def's own always-Boxed C stub
(`Compiler.RC2.Emit`'s `createCFunctions`) boxes/unboxes every
argument/return at every call, identical to upstream RefC, even when
every position involved is a primitive `CFType` whose native C
representation is already known outright from the `%foreign`
declaration's own type -- no function body to analyse, unlike Stage 2.

Narrower than Stages 1-4 in three ways that fall directly out of a
`MkRCForeign` having no `RCExp` body of its own:

- **Eligibility needs no analysis, just a type lookup.**
  `Compiler.RC2.Types.cfTypeNative : CFType -> Maybe PrimType` is the
  FFI-side counterpart to `nativeEligible`. `Int`/`Int8`/`Int16`/
  `Int32`/`Int64`/`Bits8`/`Bits16`/`Bits32`/`Bits64`/`Double` all have
  their `nativeCType` and `cTypeOfCFType` renderings agree exactly, so
  an eligible position needs zero conversion crossing the worker's own
  outer boundary -- it's the *same* C value both call sites already
  agree on. `CFChar` is the one exception: `nativeCType CharType` is
  `uint32_t` (a full Idris `Char`'s own Unicode codepoint) while
  `cTypeOfCFType CFChar` is a plain 1-byte C `char`. Rather than
  excluding it, an explicit cast handles the mismatch at the one call
  boundary where it actually surfaces -- `nativeCharArgExpr`/
  `nativeCharRetExpr`, still `Compiler.RC2.Emit`'s own helpers, just
  applied inline at each `RAppFFIInline` call site now rather than once
  inside a standalone worker's own body -- see "Stage 5" below for
  where that boundary actually lives today. `rc2/tests/Test27FFIDualABI.idr`'s
  own `prim__bumpChar` case (codepoint 254 -> 255, both past plain
  `char`'s signed range) exists specifically to catch a regression that
  drops the `unsigned char` step and sign-extends instead.
- **No wrapper rewrite -- the original `MkRCForeign` is untouched.**
  `Compiler.RC2.DualABI.ffiWorkerTable` only ever *adds* table entries
  (`Name -> (workerName, argReps, retRep)`); it never rewrites the
  `MkRCForeign` itself the way `synthesizeWorker` rewrites a `MkRCFun`
  into a thin wrapper. **Unlike Stage 3a, no standalone worker C
  function is ever emitted for this table at all** -- see "Stage 5"
  below for what actually consumes it now (an earlier design did emit
  one, via a since-deleted `Compiler.RC2.Emit.emitFFIWorker` and
  `Compiler.RC2.EmitUtil.FFIWorkers` ref; both are gone, see "Files"
  below).
- **Stage 4 needed zero changes for the non-tail case.** A
  `%foreign`-declared name's own call sites already appear as ordinary
  `RAppName` nodes in a caller's RCExp (`Compiler.RC2.RC`'s own
  `MkAForeign -> MkRCForeign` normalization is a plain pass-through,
  nothing FFI-specific about the *caller* side) --
  `applyCallSiteRewriteBody`'s existing rewrite rule already redirects
  any non-tail call whose target has a table entry, regardless of
  whether that entry came from Stage 3a or 3c, producing an ordinary
  `RAppNameRep` pointing at the synthesized worker *name* either way.
  `applyCallSiteRewrite` just unions `ffiWorkerTable`'s own first
  return value into the `workerTable` it already builds from scanning
  `MkRCFun` wrappers (`mergeWith const` -- the two key sets are always
  disjoint, a name is never both a `MkRCFun` and a `MkRCForeign`). This
  `RAppNameRep` never survives to `Emit` unchanged though -- see
  "Stage 5" immediately below. (Stage 4 *did* later need one small
  addition to also cover the tail-position case -- see "Stage 4b:
  tail-position FFI calls" after Stage 5.)

## Stage 5: FFI-inline call splicing

Stage 3c's own worker *name* only ever exists to give Stage 4 something
to rewrite an `RAppNameRep` at -- by the time `Emit` runs, that name
should never actually correspond to a standalone C function. An
earlier design did emit one (a second, native-signature C function,
`idris2rc2_ffiworker_*`, alongside the always-Boxed wrapper); this was
replaced with splicing the same marshalling logic directly into each
call site instead, via a new `RAppFFIInline` IR node
(`Compiler.RC2.RCExp`) and a dedicated pass, `inlineFFIWorkers`
(`Compiler.RC2.DualABI`), that swaps one for the other.

`ffiWorkerTable`'s own single traversal now returns *two* maps built
from the same data: the first, keyed by the *original* `%foreign` name,
is exactly what it always was -- Stage 4's own input, unchanged. The
second, keyed by the *worker's own synthesized name* instead, is
`inlineFFIWorkers`'s own input -- it needs to recognise a Stage-4-
produced `RAppNameRep` by the worker name Stage 4 already put on it
(the original function's name no longer appears anywhere on that
node), and carries the `MkRCForeign`'s own `ccs`/`fargs`/`ret` fields
verbatim, everything `RAppFFIInline` needs to render the call directly.

`inlineFFIWorkers` (`inlineFFIWorkersExp` doing the actual per-node
walk) runs as its own whole-program pass, strictly after Stage 4's
`applyCallSiteRewrite` -- a separate pass rather than folded into
`applyCallSiteRewriteBody` itself, for the same reason
`Compiler.RC2.Inline` is its own pass rather than folded into
`Compiler.RC2.RC`: Stage 4's own `RAppName`/`RLet` rewriting logic is
already involved enough without also needing FFI-specific marshalling
concerns. It's a purely structural, whole-tree rewrite with no
Rep-inference, ownership, or tail-position logic of its own (much like
`Loop.idr`'s own `renameRCExp` or `ConstFold.idr`'s own tree-walkers):
every `RAppNameRep` naming a worker the second map has an entry for
becomes `RAppFFIInline`, with `postDrop`/`args` carried over completely
unchanged -- always safe, since `argReps = map repOf fargs` is
invariant between the two node shapes, so whatever Stage 4 already
decided about ownership/promotion stays correct regardless of which
node shape ends up on the tree. `Compiler.RC2.RC2`'s own pipeline wires
this as `pure (inlineFFIWorkers ffiInlineMap rewritten)`, immediately
after `applyCallSiteRewrite`.

`Emit.idr` renders `RAppFFIInline` two ways, mirroring `RAppNameRep`'s
own always-Boxed-vs-native-context split:

- **`emitAppFFIInlineInto`** (`emitInto`'s own per-node dispatch,
  alongside `RCmpCase`/`RAppNameRep`/etc.) -- the "leftover, ordinary
  Boxed-result call" path, used whenever no enclosing `RLet` promoted
  this call's own result to native. Always produces a *Boxed* value
  string, same contract as `emitAppNameRepInto`.
- **`emitNativeValue`'s own `RAppFFIInline` case** -- the
  native-context counterpart, used instead whenever
  `Compiler.RC2.DualABI`'s own Stage 4 `RLet` promotion already decided
  this call's own result stays unboxed (exactly the `fib`-shaped
  "skip the box-then-immediately-unbox round trip" case Stage 4 exists
  for, now reachable through an FFI call too).

Both share one helper, `ffiRawCall` (itself built on a per-argument
`ffiArgMarshal`): resolves the `%foreign` declaration's own C target
(`resolveForeignTarget`, shared with `emitGenericForeignWrapper`'s own
wrapper-side resolution -- no separate header/library registration
needed here, since the wrapper for the same declaration already did
that once), marshals each argument per its own `CFType`
(`cfTypeNative`-eligible positions read directly via `rcVarToNativeC`,
`CFChar` through the same `nativeCharArgExpr`/`nativeCharRetExpr`
narrow/widen casts described below, anything else via
`rcVarToBoxedC`+`extractValue`), and emits the call itself
(`fctName(...)`, a bare statement for a `CFIORes CFUnit` target, an
expression otherwise). `emitAppFFIInlineInto` then boxes the raw result
via `packCFType` (with an explicit `(IDRIS2RC2_Value*)` cast, see "Bugs
found" below); `emitNativeValue`'s case leaves it native, widening a
`CFChar` result through `nativeCharRetExpr`.

The `CFChar` narrow/widen cast itself is unchanged from the original
Stage 3c design, just applied at each inline call site now instead of
once inside a standalone worker's own body: `nativeCType CharType` is
`uint32_t` (a full Idris `Char`'s own Unicode codepoint) while
`cTypeOfCFType CFChar` is a plain 1-byte C `char` -- `nativeCharArgExpr`
narrows `(char)` on the way into `fctName`, `nativeCharRetExpr` widens
back up through `(uint32_t)(unsigned char)` (not a direct `(uint32_t)`
cast, to zero- rather than sign-extend a `char` whose top bit is set)
on the way out -- the same narrowing/widening the always-Boxed wrapper
already pays via `idris2rc2_to_char`/`idris2rc2_mkChar`, just as a
register-width cast instead of a box/unbox round trip.
`rc2/tests/Test27FFIDualABI.idr`'s own `prim__bumpChar50` case
(codepoint 254 -> 255, absorbed from the former `Test50FFIInlineNoWorker.idr`)
exercises the same regression that same file's own `prim__bumpChar`
case always has, now through the inline path instead of a worker's own
body.

That absorbed `prim__add50`/`prim__mixed50`/`prim__noop50`/`prim__bumpChar50`
group is Stage 5's own dedicated regression/smoke test coverage --
mirrors this same file's original Stage 3c signature coverage
(all-native args+return, a mixed Int+String signature, a
`CFChar` narrow/widen round trip, an Int arg with a Boxed `CFUnit` IO
return) but under the new design, registered in `verify.sh`'s
`LEAK_SENSITIVE_TESTS`. Confirmed correct against real `idris2 --cg
refc` byte-for-byte, leak-free (`valgrind --leak-check=full`,
`definitely lost: 0 bytes`), and -- by hand -- `grep -c
idris2rc2_ffiworker_` against the generated `.c` for `Test27FFIDualABI`/
`Test33WideDualABIWorker` all return `0`:
no standalone FFI worker C function is emitted anywhere any more,
confirming the earlier `emitFFIWorker`-based design is genuinely gone,
not merely dead code.

Re-measured on `rc2/tests/Test27FFIDualABI.idr`'s own 200000-iteration
loop (`--directive nodualabi` A/B, `time`, five runs each, discarding
one cold first run per side): ~0.058s with dual-ABI (now FFI-inlined,
no separate worker function at all) vs. ~0.073s without, roughly **20%
faster** -- consistent with (and, run to run, slightly better than) the
~18% this section used to report for the standalone-worker design,
confirming the call-site-splicing rewrite didn't cost anything relative
to the worker/wrapper approach it replaced. Still smaller than `fib`'s
own 35% since this loop's own body does real non-FFI work too
(large-integer-literal casts), not purely FFI-call-bound.

## Stage 4b: tail-position FFI calls

"Scope: non-tail-position calls only, permanently" (Stage 4, above)
excludes tail-position calls from rewriting because an ordinary RC2
function's worker can itself end in a further tail call, chaining into
an otherwise-unknown-depth sequence `tryBuildClosureInto`'s closure-
deferral scheme exists to bound. A `%foreign` declaration's own worker
never can: it's a single, opaque call into external C code that
returns once and doesn't participate in this module's own tail-call
scheme at all, so the risk that scope boundary guards against simply
doesn't arise for it.

`ffiWorkerTable`'s first return value (`Name -> (workerName, argReps,
retRep, Bool)`) carries this as an explicit trailing tag, `True` for
every entry it produces; `workerTable` (the `MkRCFun`-derived table for
ordinary workers) tags its own entries `False`. `applyCallSiteRewrite`
merges the two tables as before (`mergeWith const`), now over the
tagged type, and passes the merged table straight through to
`applyCallSiteRewriteBody` unchanged. That function's non-tail
`RAppName` clause ignores the tag (either kind of worker is always
safe to redirect there, as always); a new tail-position clause reads
it, rewriting a saturated call only when the tag is `True`:

```idris
applyCallSiteRewriteBody workers reps True value@(RAppName fc _ n args) =
    case lookup n workers of
         Just (workerName, argReps, workerRetRep, True) =>
             if length args /= length argReps
                then value
                else RAppNameRep fc workerName argReps workerRetRep (postDropFor reps argReps args) args
         _ => value
```

No further pipeline change was needed. Stage 5 (`inlineFFIWorkers`)
already walks every `RAppNameRep` in the tree looking for a name its
own second table has an entry for, tail position or not, so the
`RAppNameRep` this new clause produces becomes an `RAppFFIInline` the
same way a non-tail one always has. `Emit.idr`'s `emitAppFFIInlineInto`
already threads a `TailPositionStatus`/`Sink` through correctly too
(its `SinkReturn` branch already renders any pending Boxed-argument
drop before a plain `return`, the same ordering `emitNativeReturn`
uses for an ordinary native tail value) -- it was written generically
enough from the start that this call site simply becomes reachable in
a genuine tail position for the first time, with no `Emit`-side change
required.

This only changes how the *call site* renders -- it does not make the
*calling* function itself dual-ABI-eligible. `tailAbs n = prim__abs n`
still gets an ordinary, always-Boxed wrapper for `tailAbs` itself
(Stage 2's `tailValueReps` still treats any call, including this one,
as never-native in tail position -- the *pure tail-call delegation*
limitation noted in Stage 2's own "Verification findings" above,
deliberately left alone). What changes is only that `tailAbs`'s own
body no longer defers `prim__abs`'s call via a boxed closure for the
trampoline to resolve later -- it calls `abs` directly and boxes the
result immediately before returning, one hop shorter.

`rc2/tests/refc-suite/callingConvention` (Stage 4's own golden-snapshot
test, see its own `README.md` entry) pins the generated C for exactly
this shape.

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

Stage 3b (native returns) found no new bugs of its own -- the design
review that preceded implementation (working out `emitInto`'s own
single-dispatch-point structure, and the exact "materialise then drop
then return" ordering `emitNativeReturn` needed, before writing any
code) caught what would otherwise likely have been a third entry here.
First build succeeded outright; the full verification sweep below
(including `Main.sumTo`'s own loop-plus-native-return combination,
the closest analogue to bug #2 above) passed without any fix needed.

3. **`RAppNameRep` leaked every Boxed-sourced argument it read
   natively.** Found while designing Stage 4 (call-site rewriting):
   before rewriting *more* call sites to read Boxed values natively,
   the existing Stage 3a wrapper -- already doing exactly that for
   every promoted parameter -- was re-examined empirically rather than
   just trusted. `rcVarToNativeC` (the unboxing accessor
   `RAppNameRep`'s own argument rendering uses for any `RNative`/
   `RInlineNative`-rep position) never dups/drops on its own (see its
   own doc comment) -- it only ever *reads* the value, leaving the
   original Boxed reference alive. `ROp`/`RCmpCase` already handle this
   correctly via their own `annotate`-decided `postDrop` field, but
   `RAppNameRep` had no such field at all, and -- unlike `ROp` --
   `Compiler.RC2.DualABI`'s own worker/wrapper synthesis never goes
   through `annotate`'s ownership analysis in the first place (it
   builds `RAppNameRep` nodes directly, well after `annotate` is
   already done with the whole definition), so nothing was ever
   deciding this drop was needed. `Main.fib`'s own wrapper never
   surfaced this in the existing verification sweep because every
   value it ever promotes to native during `fib 30` stays within the
   small-int cache range (`[0,100)`, backed by immortal, `refCount ==
   IDRIS2RC2_REFCOUNT_MAX` shared singletons -- `idris2rc2_drop` on one
   is unconditionally a no-op, so a *missing* drop is silently
   indistinguishable from a correct one) -- exactly the same "hidden by
   a no-op" shape that bit this project once before with 32-bit-and-
   below pointer tagging. Confirmed with `valgrind --leak-check=full`
   against a synthetic worst case (`tests/Test11DualABILeak.idr`, a
   dual-ABI-eligible function whose own promoted parameter is
   deliberately pushed outside the cache range): `31,999,984 bytes in
   1,999,999 blocks definitely lost` for 2,000,000 calls -- essentially
   one leaked allocation *per call*. Fixed by giving `RAppNameRep` its
   own `postDrop : List RCLocal` field, mirroring `ROp`'s own exactly:
   `Compiler.RC2.DualABI`'s own `synthesizeWorker` populates it for
   free (it's exactly the wrapper's own promoted parameter ids, already
   computed as `eligible` for an unrelated purpose), and
   `Compiler.RC2.Emit` gained a dedicated `emitAppNameRepInto`
   (`RAppNameRep` moved out of `emitRC`'s own "always render a Boxed
   string, no room for a pending-drop list" dispatch into `emitInto`'s
   own per-node dispatch, alongside `RCmpCase`/`RConCase`/etc.) that
   discharges `postDrop` after the call's own value has been embedded
   in its own statement -- reusing `emitNativeReturn`'s own "materialise
   into a scratch variable first" trick for a `SinkReturn` target (no
   statement position exists *after* a `return` for a drop to land in),
   plain "finalize, then drop" for a `SinkVar` target (which always has
   one). Re-verified: `valgrind` on the same synthetic case now reports
   `definitely lost: 0 bytes in 0 blocks` (`total heap usage: 14,000,124
   allocs, 14,000,024 frees` -- the 100-block gap is exactly the
   immortal small-int cache, not a leak); full refc-suite (19/19) and
   the entire `tests/Test*.idr`/`Bench*.idr` matrix re-diffed
   byte-for-byte against real `idris2 --cg refc`, unaffected.

4. **First Stage 4 attempt never actually rewrote `fib`'s own recursive
   calls, silently.** The very first working build compiled and ran
   correctly (`fib 30` still `832040`), which made this easy to miss --
   only reading the generated C directly (this project's own standing
   discipline) revealed `idris2rc2_worker_Main_fib_0`'s own body still called
   `Main_fib` (the wrapper), not itself. Root cause: the first version
   of `applyCallSiteRewriteBody` only recognised a call sitting
   *directly* as an `RLet`'s own `value`, and treated a bare `RAppName`
   reached any other way as "must be the whole function's own tail
   position, leave alone" -- an assumption that held for every shape
   tried by hand, but not for `fib(n - 1)`: Phase 1's own ANF
   normalisation of a call *argument* expression nests a further
   `RLet` **inside** the outer one's own value (`let v3 = (let v4 = n -
   1 in fib v4) in ...`), so the call itself was never directly an
   `RLet`'s own value at all, and the walk's own "must be tail
   position" fallback swallowed it. Fixed by threading an explicit
   `inTail : Bool` through the whole walk (mirroring
   `Compiler.RC2.EmitUtil`'s own `TailPositionStatus`) -- `True` only at a
   definition's own top-level entry point, threaded straight through
   every construct that doesn't change tail-ness, and *always* `False`
   while descending into an `RLet`'s own `value` -- so the *only* place
   a bare `RAppName` ever gets left alone is one reached with
   `inTail = True`, genuinely the whole function's own tail position;
   everywhere else, it's the ultimate tail of *some* value-computation
   chain and always safe to rewrite. See
   `applyCallSiteRewriteBody`'s own doc comment above for the corrected
   design.
5. **`nativeArgType`'s own established "bare tail is always Boxed"
   assumption is stale by the time Stage 4 runs.** Even after fixing
   bug #4 above, `fib`'s own worker still boxed both recursive calls'
   results (`idris2rc2_mkInt64(idris2rc2_worker_Main_fib_0(...))`) only to
   immediately unbox them again for the `+` -- the promotion itself
   never fired. `Compiler.RC2.Loop`'s own `nativeArgTypes` (reused
   directly for the promotion decision, see "Stage 4" above)
   deliberately doesn't count a *bare*, not-further-`RLet`-bound
   `ROp`/`RCmpCase` reading a candidate variable -- correctly, for
   *that pass's own* caller (`Compiler.RC2.Loop.applyLoop`, which
   always runs strictly before any function's own return eligibility
   is decided, so at the time *it* asks, a bare tail genuinely is
   always still Boxed) -- but `v3 + v5` *is* `fib`'s own worker's bare
   tail, and by Stage 4's own point in the pipeline that tail is
   already known to render natively (`Compiler.RC2.Emit`'s own
   `emitNativeReturn`, Stage 3b) precisely because the worker's own
   `retRep` already is. Reusing `nativeArgType` unmodified silently
   missed the single most important case this whole stage exists for.
   Fixed without touching `nativeArgTypes`/`nativeArgType` themselves
   (both already extensively verified elsewhere -- `export`ing the
   set-returning `nativeArgTypes` alongside the already-exported
   `nativeArgType` was the only change needed there) by adding a
   separate, Stage-4-scoped `bareTailNativeReads` that checks
   specifically for this one additional shape, unioned with
   `nativeArgTypes`'s own result before the final "exactly one
   consistent type" decision. Confirmed by reading the generated C
   directly: `fib`'s own worker now reads `int64_t var_3 =
   idris2rc2_worker_Main_fib_0(var_4); ...; return (var_3 + var_5);` -- no boxing,
   no unboxing, no dup/drop at all for either recursive call.
6. **A dual-ABI-eligible function with more than `MaxExtractFunArgs`
   (8) own top-level parameters crashed the compiler.** Found against a
   real, externally-sourced package
   ([`idris2-missing-containers`](https://github.com/seagull-kamome/idris2-missing-containers),
   see `BENCHMARKS.md`'s own re-measurement), not by anything in this
   project's own test suite (which has no function this wide) --
   `idris2 --cg refc -p missing-containers -p contrib Main.idr` failed
   outright with `INTERNAL ERROR: [rc2] RAppNameRep: more than 8 args
   not yet supported`. Root cause: `RAppNameRep`'s own emission
   (`emitAppNameRepInto` and `emitNativeValue`'s own case, see "Stage
   3a"/"Stage 4" above) has no `var_arglist[]`-style boxed-array
   extraction fallback for more than `MaxExtractFunArgs` arguments the
   way an ordinary, always-Boxed many-argument function's own
   `createCFunctions` path already does -- some of the package's own
   lambda-lifted internal helpers carry 9-23 parameters (free variables
   captured from an enclosing scope), and at least two of those had a
   genuinely native-eligible parameter among them, so a worker (and,
   for the wrapper's own call into it, an `RAppNameRep`) got
   synthesised for a function this wide -- present from Stage 3a
   onward, not introduced by Stage 4 (confirmed by bisecting the
   compiler back through Stage 3a/3b, and separately the pre-dual-ABI
   commit this whole branch started from -- all reproduced the
   identical crash once actually tested against this package, since
   nothing in this project's own suite ever exercised the shape at
   all). Fixed conservatively rather than building the extraction
   fallback (real work, and functions this wide are expected to stay
   rare): `applyDualABI`'s own `synthesizeIfEligible` now excludes any
   function with more than `MaxExtractFunArgs` parameters from dual-ABI
   eligibility entirely, unconditionally -- regardless of what
   `paramEligibility`/`returnEligibility` would otherwise decide -- the
   same blanket-exclusion shape `isMutualLoopMerged` already uses.
   `MaxExtractFunArgs` itself (`Compiler.RC2.EmitUtil`) is now `export`ed
   for this reuse, so the two limits can never drift apart by accident.
   Re-verified: full refc-suite (19/19), the entire
   `tests/Test*.idr`/`Bench*.idr` matrix re-diffed byte-for-byte against
   real `idris2 --cg refc` (none of them has a function this wide, so
   none of them is actually affected by the exclusion), `valgrind` still
   reporting zero leaks. **Separately** (not a dual-ABI bug, and not an
   environment issue either, despite first appearances): the
   `idris2-missing-containers` package's own `benchmarkHashMap` appeared
   to crash at runtime (`Unhandled input for Main.case block`) under
   *both* `idris2-rc2` and unmodified upstream `idris2 --cg refc`, and
   bisecting all the way back through every commit this branch ever
   built on reproduced the identical failure every time -- but the real
   cause, found later during a full from-scratch workspace rebuild, was
   simply running the compiled benchmark binary from the wrong working
   directory (`Main.idr`'s own `benchmarkHashMap` opens `test/words`/
   `test/input_large` via a package-root-relative path with no `Left`
   branch coded for `openFile` failure, so any wrong cwd surfaces as
   exactly this "unhandled input" crash, consistently, regardless of
   backend or commit). Run from the package root, all three backends
   (`idris2-rc2`, real `idris2 --cg refc`, real `idris2` on Chez)
   complete correctly (see `BENCHMARKS.md`'s own re-measurement).
7. **Follow-up: the >`MaxExtractFunArgs`-argument exclusion above was
   overly conservative -- properly fixed instead of left as a blanket
   exclusion.** Re-examining why the exclusion was needed at all: the
   `var_arglist[]`-style extraction fallback item 6 deferred exists
   purely to match `support/rc2/runtime.c`'s closure-dispatch function-
   pointer types (`IDRIS2RC2_FUN0`..`FUN20`/`FUNSTAR`, all
   `IDRIS2RC2_Value*`-only) -- a convention that only matters for a
   function that might actually be *dispatched through a `Closure`*.
   A dual-ABI **worker** never is: it's reachable only via a direct,
   statically-named, fully-saturated `RAppNameRep` call (from its own
   wrapper's body, or a Stage 4 non-tail call-site rewrite), never
   stored in a `Closure` at all. Its **wrapper** (the original
   function's own name, always Boxed) is what remains closure-
   dispatch-compatible, and was never the thing item 6's crash was
   actually about. So the real fix isn't "build the extraction
   fallback" (item 6's deferred "real work") -- it's "exempt workers
   from needing it in the first place": `MkRCFun` gained an `isWorker`
   field (`True` only for `synthesizeWorker`'s own worker, `False`
   everywhere else including the wrapper), and `Compiler.RC2.Emit`'s
   `createCFunctions` now only falls back to the `var_arglist[]`
   declaration shape for a non-worker past `MaxExtractFunArgs`
   parameters -- a worker keeps individually-typed (native where
   eligible) positional parameters regardless of its own width.
   `applyDualABI`'s `synthesizeIfEligible` no longer excludes wide
   functions at all (only `isMutualLoopMerged` remains). Verified with
   `rc2/tests/Test33WideDualABIWorker.idr` (10 parameters: nine native-
   eligible `Int`s + one `Boxed` `String`, mirroring the original
   `idris2-missing-containers` shape) -- generated C declares
   `idris2rc2_worker_Main_wideAdd_0` with ten individual parameters
   (nine `int64_t`, one `IDRIS2RC2_Value *`), called directly with no
   `var_arglist[]`/boxing/trampoline involved; full refc-suite,
   smoke-test matrix, and `valgrind` (`0 bytes definitely lost`) all
   still pass. Stage 3c's own separate FFI worker exclusion
   (`ffiWorkerTable`'s `length fargs > MaxExtractFunArgs`) was left
   untouched -- see `TODO.md`'s own note on why.
8. **`MaxExtractFunArgs` itself raised from 8 to 20, with
   `support/rc2/runtime.c` extended to match.** Both item 7's worker
   exemption and Stage 3c's own `ffiWorkerTable` exclusion move to the
   new threshold automatically -- same symbolic constant, no code
   change needed at either call site. The runtime side did need a real
   change: `idris2rc2_dispatchClosure`'s switch only had `case 0`..
   `case 8` (falling through to `default`/`IDRIS2RC2_FUNSTAR` for any
   wider arity), so a genuine `Closure` of arity 9-20 -- reachable
   whenever a wide, native-eligible-parameter function's own *wrapper*
   is partially applied rather than called directly (a worker itself is
   never dispatched this way, per item 7) -- would have silently taken
   the untyped `var_arglist[]` path instead of the correctly-typed
   function pointer. Added `IDRIS2RC2_FUN9`..`IDRIS2RC2_FUN20` typedefs
   (same hand-written style as the existing `FUN0`..`FUN8`) and `case
   9`..`case 20` in `dispatchClosure` to match. A stale comment in
   `runtime.c` pointing at `Compiler/RC2/RC2.idr` for where
   `MaxExtractFunArgs` lives was also corrected to
   `Compiler/RC2/EmitUtil.idr`, its real location. Verified with
   `rc2/tests/Test33WideDualABIWorker.idr`'s own `add20` (formerly a
   separate `Test34WideClosureDispatch.idr`, merged in) -- a
   20-parameter function reached via a genuine partial-application
   chain (not a direct/saturated call), forcing it through a real
   `Closure` and `dispatchClosure` to exercise the new `case 9`..`case
   20` paths, the way that same file's own `wideAdd`/`prim__wide`
   exercise the worker-side width exemption; registered in
   `verify.sh`'s `LEAK_SENSITIVE_TESTS`,
   `valgrind` confirming `0 bytes definitely lost`. Full refc-suite
   (19/19) and smoke-test matrix still pass; `bench.sh` shows no
   regression.
9. **Follow-up to item 7: Stage 3c's own separate FFI worker exclusion,
   left untouched there, was investigated and removed too.** Item 7
   left `ffiWorkerTable`'s own `length fargs > MaxExtractFunArgs`
   cutoff (`DualABI.idr`'s `ffiEntry`) in place unconditionally,
   noting only that the same "the callee side never needs the
   closure-dispatch convention" argument plausibly applied but hadn't
   actually been checked against this structurally distinct code path
   (`MkRCForeign`, not `MkRCFun`). Checked now, and it does apply
   without modification: an FFI worker is never stored in a `Closure`
   either -- closure construction always uses the wrapper's own
   original name, and the worker's own name is reachable only via a
   direct, statically-named `RAppNameRep` call, so it never needs to
   satisfy `support/rc2/runtime.c`'s `IDRIS2RC2_FUN0`..`FUN20`/
   `FUNSTAR` convention that the width limit existed to protect. And
   unlike Stage 3a's own worker-synthesis path, Stage 3c's own
   `emitFFIWorker` (`Compiler.RC2.Emit`) never had a width-dependent
   `var_arglist[]` fallback to route around in the first place --
   `declareParam` always emits individually-typed positional
   parameters regardless of arity, so item 6's original bug
   structurally couldn't occur here at all. `extractValue`/
   `packCFType`/`nativeCType` are all purely positional,
   arity-independent transforms too, with nothing in them that changes
   shape past 20 parameters. So `ffiEntry`'s own `if length fargs >
   MaxExtractFunArgs then pure [] else ...` cutoff was removed outright
   -- every `%foreign` declaration now always reaches the
   natively-eligible-position check (`if not (any anyNative argReps)
   && not (anyNative retRep) then pure [] else ...`) regardless of its
   own arity, with no width-based exclusion left anywhere in Stage 3c.
   Verified with `rc2/tests/Test33WideDualABIWorker.idr`'s own
   `prim__wide` (formerly a separate `Test48WideFFIDualABIWorker.idr`,
   merged in) -- a 15-parameter `%foreign` declaration -- 12
   native-eligible `Int`s + 3 `Boxed` `String`s, a "mostly native, some
   Boxed" shape but past what the old limit would
   have excluded -- called fully saturated from `main` so Stage 4's own
   call-site rewriting fires): the generated C was inspected by hand
   and shows `idris2rc2_ffiworker_Main_prim__wide_0` declared with 12
   individually-typed `int64_t` parameters plus 3 `IDRIS2RC2_Value *`
   parameters (no `var_arglist[]` anywhere), and `main`'s own call site
   calling the worker directly, confirming Stage 4's own rewrite fired.
   `verify.sh --regen-expected` (full suite, 85/85) and
   `refc-suite/run.sh` (19/19) both still pass; `valgrind
   --leak-check=full` reports `0 bytes definitely lost` for this test
   (registered in `verify.sh`'s `LEAK_SENSITIVE_TESTS`). See
   `KNOWN-BUGS.md`'s "Retired: FFI worker synthesis (Stage 3c) no
   longer has its own argument-count limit" for the closed-out
   `TODO.md` entry this resolves.
10. **A literal-constant FFI argument broke the Boxed-argument-drop
    tracking, a C compile failure.** Found while building Stage 5's own
    `emitAppFFIInlineInto`/`ffiRawCall`: an earlier version of
    `ffiArgMarshal`'s Boxed-position drop set (what became
    `ffiRawCall`'s own `boxedArgDrop`) carried raw `RCLocal`s, rendered
    via the same bare `varName` every ordinary `postDrop` entry already
    uses safely. That assumption -- "every dropped argument is a named
    variable" -- doesn't hold for a raw FFI call argument specifically:
    unlike an `RAppNameRep`'s own `postDrop` (always a genuine `RCLoc`
    by construction, see its own doc comment), a `%foreign` call's own
    Boxed-typed argument can itself be a literal `RCConst` (e.g. a
    `String` literal passed with no enclosing `let`) -- `varName`'s own
    `RCConst` case is a deliberately-unreachable placeholder everywhere
    else in `Emit.idr` precisely because nothing else ever hands it
    one, and it produced an undeclared/wrong C identifier, a compile
    failure rather than a silent runtime bug. Fixed by carrying
    already-rendered C expression text for the drop set instead of raw
    `RCLocal`s -- `ffiArgMarshal` now returns `(String, Maybe String)`
    (the argument's own render, and separately its own drop-ready
    render when genuinely Boxed, via the same `rcVarToBoxedC` that
    already handles constant-staging/`InlineMap` correctly), which
    widened `emitNativeValue`'s own "pending drop" contract from `List
    RCLocal` to `List String` project-wide (every other producer --
    `RV`, `RAppNameRep`, `ROp` -- already had a genuine `RCLocal` in
    hand, so this only ever meant one extra `map varName` at each of
    those existing call sites, not a behavior change for them).
    Re-verified: `rc2/tests/Test27FFIDualABI.idr`'s own
    `prim__mixed50` (a `String`-typed argument) compiles and runs
    correctly; full `verify.sh` (all tests) and `refc-suite/run.sh`
    (19/19) unaffected.
11. **A missing `(IDRIS2RC2_Value*)` cast on `emitAppFFIInlineInto`'s
    own boxed-return path, a `-Wincompatible-pointer-types` compile
    failure.** `emitGenericForeignWrapper`'s own pre-existing
    boxed-return handling already casts `packCFType`'s own result
    explicitly, because `packCFType`'s "mk" functions don't all
    literally return `IDRIS2RC2_Value *` (e.g. `CFStruct`/`CFPtr`'s own
    `idris2rc2_mkPointer` returns `IDRIS2RC2_Pointer *`) -- the first
    version of `emitAppFFIInlineInto` (Stage 5's always-Boxed-result
    renderer) omitted this cast on its own, structurally identical
    `packCFType (peelIORes ret) rawExpr` call, since it was written
    fresh rather than copied from the wrapper's own code. Silent for
    every purely-scalar `%foreign` declaration in the existing test
    suite (their own `packCFType` results already happen to be
    `IDRIS2RC2_Value *`), only surfacing as a real compile error for a
    `CFStruct`/pointer-returning declaration -- exactly the shape
    `emitGenericForeignWrapper`'s own comment already flagged this
    exact hazard for. Caught by `rc2/tests/Test24CStructSupport.idr`'s
    own `prim__makePoint : Int -> Double -> PrimIO Point` -- both
    arguments native-eligible (so it gets an FFI worker at all) but its
    `Point` return is `CFStruct` (Boxed, so `packCFType`'s own
    `IDRIS2RC2_Pointer *`-returning path is exercised); called in a
    genuine non-tail position (`p <- primIO (prim__makePoint 3 4.5)`
    inside `main`'s own `do` block), so Stage 4/5 actually rewrite this
    call site and hit `emitAppFFIInlineInto`'s own Boxed-result render.
    Fixed by adding the same explicit `(IDRIS2RC2_Value*)` cast,
    matching the wrapper's own established convention verbatim.
    Re-verified: `Test24CStructSupport.idr` compiles and runs correctly
    again; full `verify.sh`/`refc-suite` unaffected.

## Status

**Fully implemented and verified** (Stages 1, 2, 3a, 3b, 3c, 4, 5).

Stage 3c+5 (FFI call-site inlining): `rc2/tests/Test27FFIDualABI.idr`'s
own `prim__add` still compiles to a wrapper (`Main_prim__add`,
unchanged Boxed signature, `extractValue`/`packCFType` untouched), but
there is no longer a standalone worker C function at all -- the test's
own self-tail-recursive `loop` (already a native `int64_t` goto-loop
via `Compiler.RC2.Loop`) now calls `idris2rc2_test27_add` (the raw
`%foreign`-declared C function itself) directly from inside its own
body, via a `RAppFFIInline` node Stage 5 spliced in, no boxing, no
unboxing, and no intervening worker function at that call at all.
Confirmed correct against real `idris2 --cg refc` byte-for-byte,
leak-free (`valgrind --leak-check=full`, `definitely lost: 0 bytes`),
the full refc-suite (19/19) and entire smoke-test matrix still
passing, and a measured win on that test's own 200000-iteration loop
(`--directive nodualabi` A/B): ~0.058s with dual-ABI enabled vs.
~0.073s without, ~20% faster (see "Stage 5" above for the full
re-measurement).

`Main.fib`
compiles to a wrapper (`Main_fib`, unchanged Boxed signature, every
existing caller anywhere else keeps working unmodified) plus a worker
(`idris2rc2_worker_Main_fib_0`) doing the real recursive work entirely in native
`int64_t`, with **both of its own recursive calls now targeting the
worker directly** -- no boxing, no unboxing, no heap allocation, no
dup/drop anywhere in this computation, the whole thing staying in
`int64_t` from the worker's own entry to its own `return` (see Stage 4's
own before/after code sample above for the generated C). Confirmed correct (`832040`
for `fib 30`), confirmed leak-free (`valgrind --leak-check=full`,
`definitely lost: 0 bytes` across `tests/BenchFib.idr`,
`tests/BenchLoop.idr`, `tests/BenchChain.idr`,
`tests/Test11DualABILeak.idr`), the full refc-suite (19/19) and the
entire smoke-test/benchmark matrix re-verified byte-for-byte against
real `idris2 --cg refc`, and -- for the first time in this whole
effort -- a **measured** performance win: `fib 30`, timed directly
(`time`, three runs each), runs in ~0.14s under `idris2-rc2` versus
~0.21s under real `idris2 --cg refc`, roughly **35% faster** on the
flagship non-tail-recursive case this whole effort exists for.

Tail-position calls remain permanently out of scope (see "Scope" under
"Stage 4" above) -- not a future stage, a deliberate, considered
boundary matching `returnEligibility`'s own "pure delegation" exclusion
from Stage 2.

## Files

- `rc2/src/Compiler/RC2/DualABI.idr` -- `paramEligibility`/
  `returnEligibility`/`tailValueReps` (Stage 2), `synthesizeWorker`/
  `applyDualABI`/`isMutualLoopMerged`/`FreshId` (Stage 3a+3b:
  `synthesizeWorker` now promotes both `workerArgs` and `workerRetRep`
  independently of `wrapperRetRep`), `describeEligibility`/
  `dumpDualABI` (the `--directive dumpdualabi` debug dump),
  `ffiWorkerTable` (Stage 3c -- no `RCExp` to analyse, so no
  `paramEligibility`/`returnEligibility` reuse; `freshName` now takes
  an explicit `pfx` so Stage 3a's `"idris2rc2_worker_"` and Stage 3c's
  `"idris2rc2_ffiworker_"` share the one collision-checked namer; now
  returns *two* maps from one traversal -- the original-name-keyed one
  Stage 4 always took, plus a worker-name-keyed one for Stage 5's own
  use), `workerTable`/`applyCallSiteRewriteBody`/`applyCallSiteRewrite`/
  `ultimateTail`/`bareTailNativeReads`/`nativePromotionFor`/
  `postDropFor`/`localRepIn` (Stage 4: `applyCallSiteRewrite` now takes
  Stage 3c's own original-name-keyed table as an explicit argument and
  `mergeWith const`s it into the `MkRCFun`-derived `workerTable`,
  unchanged otherwise -- Stage 4 itself has no idea Stage 5 exists),
  `inlineFFIWorkersExp`/`inlineFFIWorkers` (Stage 5 -- the whole-tree
  `RAppNameRep` -> `RAppFFIInline` rewrite, run after
  `applyCallSiteRewrite`, keyed off Stage 3c's own worker-name-keyed
  table).
- `rc2/src/Compiler/RC2/RCExp.idr` -- `MkRCFun`'s new shape,
  `RAppNameRep` (now with its own `postDrop` field, mirroring `ROp`'s
  own, added for the reference-leak fix above), `RAppFFIInline` (Stage
  5 -- carries a `%foreign` declaration's own `ccs`/`fargs`/`ret`
  fields verbatim, deliberately un-precomputed unlike `RAppNameRep`'s
  own `argReps`/`retRep`, plus a `postDrop` field always inherited
  unchanged from the `RAppNameRep` it replaces).
- `rc2/src/Compiler/RC2/Loop.idr` -- `nativeArgType`/`nativeArgTypes`/
  `stripOwnership` now `export`ed for `Compiler.RC2.DualABI`'s own
  reuse; defensive `RAppNameRep` pass-through case in `renameRCExp`
  (now also renaming `postDrop`).
- `rc2/src/Compiler/RC2/RC.idr` -- `normalizeDef`/`annotateDef` updated
  for `MkRCFun`'s new shape; defensive `RAppNameRep` pass-through case
  in `annotate`.
- `rc2/src/Compiler/RC2/MutualLoop.idr` -- updated for `MkRCFun`'s new
  shape (merged function and per-member wrappers both still always
  `RBoxed`, unconditionally, by this pass's own design).
- `rc2/src/Compiler/RC2/Emit.idr` -- `createCFunctions` now `Rep`-aware
  for both a function's own return-type declaration and each
  parameter's own declaration/`RepMap` seeding; `Sink`'s own
  `SinkReturn` constructor now carries a `Rep` (Stage 3b); new
  `emitNativeReturn`; `emitNativeValue`'s new bare-`RV` case (Stage 3b)
  and new `RAppNameRep` case (Stage 4, for a promoted `RLet`'s own
  native-consuming render);
  `emitInto`'s fallback arm dispatches to `emitNativeReturn` for a
  native `SinkReturn`; `RAppNameRep` moved out of `emitRC`'s own
  dispatch entirely into a new, dedicated `emitAppNameRepInto`
  (`emitInto`'s own per-node dispatch, alongside `RCmpCase`/`RConCase`/
  etc.) that discharges its own `postDrop`; `cName` now `export`ed for
  `Compiler.RC2.DualABI`'s own worker-naming reuse; `nativeCharArgExpr`/
  `nativeCharRetExpr` (the explicit `CFChar`-only cast a native
  argument/return needs, now applied inline at each `RAppFFIInline`
  call site -- see "Stage 5" above). Stage 5 itself: `resolveForeignTarget`
  (shared with `emitGenericForeignWrapper`'s own wrapper-side
  resolution), `ffiArgMarshal`/`ffiRawCall` (per-argument marshalling +
  the call itself, shared between the two renderers below), new
  `emitAppFFIInlineInto` (`emitInto`'s own per-node dispatch, the
  always-Boxed-result renderer) and a new `RAppFFIInline` case on
  `emitNativeValue` (the native-context renderer, used whenever an
  enclosing `RLet` promoted this call's own result to native). The
  since-removed `emitFFIWorker` and `Compiler.RC2.EmitUtil`'s
  since-removed `FFIWorkers` ref -- an earlier design's standalone
  native-signature FFI worker function and the ref that told
  `createCFunctions` to emit it -- are gone entirely; no code anywhere
  emits a second C function for a `%foreign` declaration any more.
- `rc2/src/Compiler/RC2/Types.idr` -- `cfTypeNative` (Stage 3c's own
  `CFType`-side eligibility, the FFI counterpart to `nativeEligible`).
- `rc2/src/Compiler/RC2/Pretty.idr` -- `MkRCFun`'s new
  `args`/`retRep` rendering; `RAppNameRep`'s own `callRep` rendering
  (now including `postDrop`).
- `rc2/src/Compiler/RC2/RC2.idr` -- `toRCDefs`'s own pipeline wiring:
  `applyDualABI`, then `ffiWorkerTable` (now unpacked into
  `(ffiWorkers, ffiInlineMap)`), then `applyCallSiteRewrite ffiWorkers`,
  then `pure (inlineFFIWorkers ffiInlineMap rewritten)` -- Stage 5 as
  the pipeline's own last step before `Compiler.RC2.Emit`; `--directive
  dumpdualabi` wiring, unaffected (still reads the pre-Stage-5 def
  list). No `FFIWorkers` ref/`generateCSourceFile` leading argument any
  more -- the FFI-inline table is consumed entirely as an IR rewrite,
  never threaded down into `Emit`'s own state.
- `rc2/tests/Test11DualABILeak.idr` -- regression test for the
  reference-leak bug above; verify with `valgrind --leak-check=full`,
  not just a stdout diff (see the test file's own comment).
- `rc2/tests/Test27FFIDualABI.idr`/`.c`/`.h` -- Stage 3c/5's own
  original regression/smoke test, also absorbing the former, separate
  `Test50FFIInlineNoWorker.idr`'s dedicated Stage 5 coverage (written
  specifically to confirm no standalone `idris2rc2_ffiworker_*` C
  function is emitted any more; registered in `verify.sh`'s
  `LEAK_SENSITIVE_TESTS`); verify with `valgrind --leak-check=full`,
  same reasoning as `Test11DualABILeak.idr` above.

## Verification methodology

1. Build + regression baseline: see `CLAUDE.md`'s "Build & test" section
   (`idris2 --build rc2.ipkg`, then `tests/refc-suite/run.sh`, expect 19/19).
2. `--directive dumpdualabi` (see Stage 2's own section above) on any
   candidate function is the fastest way to confirm eligibility
   *before* looking at generated C at all -- e.g. `grep "Main.fib"
   out.dualabi` should show `params=[Int] ret=Int`. Note this dump
   runs on the *post-`applyDualABI`* def list (`RC2.idr`'s own pipeline
   position) -- once a function's own worker has actually been
   synthesised, the *original* name now names the thin wrapper (Boxed
   params/return, by design), so it correctly shows `Boxed`/`Boxed`
   there too; the interesting native findings are what the worker
   itself got built with, visible directly in the generated C instead
   (next step).
3. `tests/BenchFib.idr` is the canonical smoke test for every stage:
   `fib 30` must still print `832040`; `grep -n "^int64_t idris2rc2_worker_\|
   ^IDRIS2RC2_Value \*idris2rc2_worker_" build/exec/*.c` confirms a worker
   actually got synthesised and shows whether its own return ended up
   native, and reading its own C body directly confirms (a) the
   promoted parameter/return are declared with their native C types,
   (b) a pending-Boxed-operand-drop tail value renders as
   "materialise into a temp, drop, then return" (never a drop directly
   ahead of a bare `return`), and (c) -- **now that Stage 4 is
   implemented** -- the original's own recursive calls target the
   *worker* directly (`idris2rc2_worker_Main_fib_0`, not `Main_fib`), with no
   remaining `idris2rc2_mkInt64`/`idris2rc2_to_i64` pair around either
   call. `tests/BenchLoop.idr`'s own `Main.sumTo` is the loop-combination
   smoke test -- its worker's own loop-exit tail value must render
   through the same native path.
4. Full `tests/Test*.idr`/`tests/Bench*.idr` suite, diffed against real
   `idris2 --cg refc` output, same as every other stage in this
   project -- both stages are supposed to be purely structural/codegen
   changes, so *every* test must still match byte-for-byte, with zero
   observable behaviour difference. `Test7CastMatrix.idr` can't be
   diff-checked against real `idris2 --cg refc` at all right now: the
   nixpkgs-bundled RefC support library itself fails to compile
   (`idris2_negate_Double` typo'd as `idris2_nagate_Double` in its own
   headers, plus a couple of missing declarations) -- confirmed to be a
   defect in that reference installation itself, unrelated to rc2;
   `idris2-rc2`'s own build of the same file compiles and runs cleanly,
   so this is a coverage gap in cross-checking this one file, not a
   known or suspected rc2 bug.
5. **A stdout diff alone can't catch a reference leak** -- one existed
   in `RAppNameRep`'s own argument handling for a full stage-and-a-half
   (Stage 3a through most of Stage 3b) without ever failing a single
   diff, precisely because it doesn't corrupt any computed value. Any
   change to `RAppNameRep`'s own emission, or to `Compiler.RC2.DualABI`'s
   own worker/wrapper synthesis, should also be checked with `valgrind
   --leak-check=full` against `tests/Test11DualABILeak.idr` (deliberately
   pushes its own promoted parameter's values outside the small-int
   cache range, so a missing drop can't hide as a silent no-op the way
   it did in `Main.fib`/`Main.sumTo`'s own recursion) -- expect
   `definitely lost: 0 bytes in 0 blocks` (only the 100-entry immortal
   small-int cache should show as `still reachable`).
6. **Once Stage 4 is actually rewriting call sites, verify the
   performance win directly** -- `time ./build/exec/<BenchFib output>`
   a few times, next to the same for a real-`idris2 --cg refc` build of
   the same file. `fib 30` (`tests/BenchFib.idr`) went from parity/
   slightly-behind RefC (every earlier stage in this project's own
   history, per `BENCHMARKS.md`) to roughly **35% faster** once Stage 4
   actually landed -- if a future change to this pipeline regresses
   that back towards parity, that's a real signal something stopped
   rewriting or promoting a call site that used to be, worth
   investigating with `--directive dumprcexpr` and a direct read of the
   generated C (steps 2-3 above) before assuming it's just noise.
