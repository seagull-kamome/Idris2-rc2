# Changes

Newest first. Each entry corresponds to one commit on `master`; see
`git log` for full commit messages.

## 2026-08-14 -- Dual calling convention: worker/wrapper synthesis for native returns, Stage 3b

Fourth of the staged `dual-abi` effort, completing the worker/wrapper
split Stage 3a started: a worker's own `retRep` is now promoted to
`RNative` when `Compiler.RC2.DualABI`'s own (Stage 2) `returnEligibility`
found one, instead of always staying `RBoxed`. `Main.fib`
(`tests/BenchFib.idr`) now compiles to a worker whose own C signature
is `int64_t rc2_dualABI_0(int64_t var_0)` -- both parameter *and*
return native, the whole recursive computation staying in `int64_t`
throughout, boxed back up only once, in the unchanged wrapper, for
whatever still-Boxed caller reads the final result.

The change turned out smaller than its own risk assessment suggested:
`Compiler.RC2.Emit`'s own control flow was already centralised enough
(every branching construct threads the same `Sink` down to its own
branches, all the way to one shared fallback for a genuine leaf value)
that making `Sink`'s own `SinkReturn` constructor carry a `Rep`, and
teaching that one fallback arm to dispatch to a new `emitNativeReturn`
for a native `SinkReturn`, was enough -- no changes needed to
`emitCmpCaseInto`/`emitConCaseInto`/`emitConstCaseInto`/`emitLoopInto`
themselves. `emitNativeReturn` solves the same "must drop a pending
Boxed operand only after the statement that reads it" ordering problem
`declareNative` already solved for an `RLet`, adapted for `return`'s
own lack of any statement position *after* it to run a deferred drop
in: materialise the value into a scratch variable first (only when
there's actually a pending drop to sequence around), drop, then return
the scratch variable. `Main.sumTo` (`tests/BenchLoop.idr`) exercises
the loop-plus-native-return combination in the same function, its own
loop-exit tail value rendering through the very same fallback path.

Unlike Stage 3a, this stage found no new bugs of its own -- attributed
to the design review that preceded implementation (working out
`emitInto`'s own single-dispatch-point structure, and the exact
`emitNativeReturn` drop-ordering, before writing any code). Full
design, implementation detail, and verification are in
`rc2/doc/dual-abi.md`'s own "Stage 3b" section.

Verified: full refc-suite (19/19), the `tests/Test*.idr`/`Bench*.idr`
smoke-test/benchmark matrix rebuilt and diffed byte-for-byte against
real `idris2 --cg refc` output (including the `Main.sumTo`
loop-combination case above), and `fib 30` confirmed to still compute
`832040` with its worker's own return now genuinely native throughout
-- read directly off the generated C, not just inferred from matching
output.

## 2026-08-14 -- Dual calling convention: worker/wrapper synthesis for parameters, Stage 3a

Third of the staged `dual-abi` effort, split from the original Stage 3
plan into a parameters-only step (native returns deferred to Stage 3b
-- see `rc2/doc/dual-abi.md`'s own plan-reconsideration note) after
scoping showed native-return rendering needed materially riskier
changes to `Emit.idr`'s highest-traffic `Sink`/`SinkReturn` code. New
`RAppNameRep` IR node and `Compiler.RC2.DualABI`'s `synthesizeWorker`/
`applyDualABI` generate, for every parameter-eligible (per Stage 2's
own analysis) and non-`MutualLoop`-merged function, a freshly
synthesised internal *worker* with native C types at its eligible
parameter positions, plus a rewritten *wrapper* (the function's own
original name and Boxed signature, now a thin shim calling the
worker) -- the classic GHC-style worker/wrapper split. `Main.fib`
(`tests/BenchFib.idr`) now compiles to `Main_fib` (unchanged Boxed
wrapper) unboxing its argument once and calling a synthesised
`rc2_dualABI_N` worker doing the real recursive work in `int64_t`
throughout its own body. No performance change yet -- every call site
elsewhere in the program still targets the unchanged wrapper; that
rewrite is Stage 4's own job.

Two real bugs found and fixed during this stage's own build-and-test
cycle: (1) `createCFunctions` not yet `Rep`-aware for a function's own
C parameter declarations/`RepMap` seeding, caught immediately on the
first build of `fib`'s worker (C type mismatch between the wrapper's
unboxed call and the worker's still-`IDRIS2RC2_Value *` declared
parameter); (2) `Compiler.RC2.Loop`'s own `declareLoopParam` NULL guard
(written for `MutualLoop`'s `RCNull` padding case) applied
unconditionally even when `initVal` was already native -- breaking any
function that's *both* self-tail-recursive and dual-ABI-eligible
(`Test1Basics.idr`, `Test9SelfTailLoop.idr`, `BenchLoop.idr`,
`BenchChain.idr`), a pointer-vs-integer C comparison error under
`-Werror`. Both fixed; full detail (root cause, fix, verification) in
`rc2/doc/dual-abi.md`'s own "Bugs found and fixed" section.

Verified: full refc-suite (19/19), the `tests/Test*.idr`/`Bench*.idr`
smoke-test/benchmark matrix rebuilt and diffed byte-for-byte against
real `idris2 --cg refc` output, and `fib 30` confirmed to still compute
`832040` through the new worker/wrapper split.

## 2026-08-14 -- Dual calling convention: eligibility analysis, Stage 2

Second of the staged `dual-abi` effort. New `Compiler.RC2.DualABI`
module decides, per top-level function, which of its own parameters and
whether its own return value could be given a native representation at
the function's own external C signature -- read-only, nothing is
synthesized or rewritten yet. Both analyses are purely local to one
function's own body, needing no whole-program fixed point: a
parameter's eligibility reuses `Compiler.RC2.Loop`'s own `nativeArgType`
(now exported), or, for an already-`RLoop`-wrapped body, reads the
answer straight off that loop's own `loopParams`; a tail-position
return value's eligibility comes from the same local analysis, seeded
with each already-decided parameter's own Rep so a bare tail return of
an eligible parameter counts too.

Verified via a new `--directive dumpdualabi` debug dump (mirroring
`dumprcexp`) against the existing test/benchmark suite: `Main.fib`
(the non-tail-recursive target this whole effort exists for) correctly
comes back `params=[Int] ret=Int`; `Main.sumTo` correctly reads
`Compiler.RC2.Loop`'s own decision; `Main.countDown`/`collatzLike`
correctly show mixed (one native, one Boxed) parameter eligibility;
every `Compiler.RC2.MutualLoop` per-member wrapper correctly shows no
eligibility. One finding that changes Stage 3's own plan: a
`MutualLoop`-*merged* function itself (as opposed to its per-member
wrappers) can show real eligibility for a slot some group member reads
natively even though a smaller-arity member only ever supplies `RCNull`
there -- confirmed directly against `Test10MutualLoop.idr`'s own
`stepA`/`stepB` group, the exact shape that already caused two crashes
during the loop-conversion work. Stage 3 must explicitly exclude every
`MutualLoop`-produced merged function from worker synthesis.

## 2026-08-14 -- Dual calling convention: MkRCFun carries per-arg/return Rep, Stage 1

First of a staged effort (branch `dual-abi`, see `TODO.md`'s "Dual
calling convention" gap and its own plan discussion) to let native
representations cross ordinary function-call boundaries, not just a
self-tail-call loop's own `goto`. `RCDef`'s `MkRCFun` now carries `(args
: List (Int, Rep))` and a `retRep : Rep` instead of a bare `List Int`
(always-Boxed) argument list -- mirroring `RLoop`'s own "carries its own
Reps" shape, at the whole-function granularity instead of a single
loop's. Every existing construction site (`RC.idr`'s `normalizeDef`,
`MutualLoop.idr`'s merged function and per-member wrappers) supplies
`RBoxed` uniformly, matching today's implicit behavior exactly; no pass
yet promotes anything. Deliberately deferred to a later stage: making
`Emit.idr`'s own function-signature declaration and `SinkReturn`
rendering actually Rep-aware -- building that now, before anything
exercises the non-`RBoxed` path, would mean shipping untested code (the
loop-conversion work's own "Bugs found" history is exactly why this
project keeps to "verify byte-identical before adding real behavior").

Verified: generated C for every `tests/Test*.idr`/`tests/Bench*.idr`
file, compiled with both this commit's compiler and `master`'s,
confirmed byte-for-byte identical; 19/19 refc-suite tests still pass.

## 2026-08-13 -- Promote loop-carried parameters to native representation, Stage 3

The optimization Stage 1/2's `RLoop`/`RLoopContinue` split was groundwork
for: `Compiler.RC2.Loop`'s `applyLoop` now decides, per top-level
parameter of a self- or (post-MutualLoop-merge) mutually-tail-recursive
loop, whether the loop body reads it as a native-context operand
anywhere (an `RLet`-bound `RNative`/`RInlineNative` `ROp`, or a fused
`RCmpCase`) consistently at one `PrimType`; if so, promotes it to a
fresh native-shadow loop param (unboxed once at loop entry, dropped
there), redirecting every other reference to the shadow
(`renameRCExp`, factored out and shared with `Compiler.RC2.MutualLoop`'s
own per-member renaming) and stripping the original's now-stale
ownership bookkeeping (`stripOwnership`) -- eliminating the
box-then-immediately-reunbox round trip a loop-carried numeric value
used to pay at every `goto` back to the top. Also fixes redundant
*within-iteration* unboxing of a multiply-used native operand as a side
effect.

Two real bugs found and fixed during verification: `RConstCase`'s
scrutinee handling (`emitConstCaseInto`) assumed it was always read
Boxed, breaking once a loop param pattern-matched against a literal
constant (e.g. `sumTo`'s own `0` check) became a native shadow --
now Rep-aware. And `Compiler.RC2.MutualLoop`'s own `RCNull` arity
padding could reach a slot promoted to native by a *different* group
member, crashing on an unboxed-NULL dereference (`Test10MutualLoop.idr`'s
differing-arity `stepA`/`stepB` group caught this) -- fixed by treating
`RCNull` as a safe native `0` in `rcVarToNativeC`, plus a one-time
runtime NULL guard on `declareLoopParam`'s own loop-entry unboxing.

Verified: `BenchLoop.idr`'s `sumTo` now runs its entire loop as pure
native `int64_t` arithmetic, zero heap allocation/refcount traffic per
iteration; generated C for `Test9SelfTailLoop.idr` (mixed native-eligible
and non-eligible params in one loop) inspected directly; 19/19
refc-suite tests, all smoke tests, and all benchmarks re-verified
byte-for-byte/crash-free against `idris2 --cg refc`.

## 2026-08-13 -- Adapt Compiler.RC2.MutualLoop to RLoop/RLoopContinue, Stage 2

Second of the two staged steps (see Stage 1). `Compiler.RC2.MutualLoop`
itself needed no *design* changes -- it was already deliberately
agnostic to how `Compiler.RC2.Loop` represents a converted loop
internally, by design: it only ever produces an ordinary tail-position
`RAppName` targeting its own synthesised merged function, relying
entirely on `Compiler.RC2.Loop` (which still runs immediately
afterward, unchanged in this regard) to recognize and convert it -- and
that recognition (`mapTailAppNames`) didn't change in Stage 1 either.
The only changes needed were mechanical: adapting to `MkRCFun`'s new
2-field shape (no more `isLoop`) at its own two construction sites, and
adding defensive `RLoop`/`RLoopContinue` pass-through cases to
`renameRCExp` (never actually reached in practice -- this pass runs
strictly before `Compiler.RC2.Loop`, the sole producer of both).

Verified: `Test10MutualLoop.idr`'s merged `isEvenM`/`isOddM` function
(and every other test) generates byte-for-byte identical C to before
Stage 1/2 (`loop:;` placement, goto-reassignment, tag dispatch all
unchanged); 19/19 refc-suite tests and all smoke tests still match
`idris2 --cg refc`; benchmarks unaffected.

## 2026-08-13 -- Represent self-tail-call loops as explicit IR (RLoop/RLoopContinue), Stage 1

First of two staged steps toward letting a loop's own carried state have
a representation independent of its enclosing function's (always Boxed)
calling convention. New `RLoop`/`RLoopContinue` IR nodes replace
`MkRCFun`'s `isLoop` flag and `RSelfTailCall`: `RLoop` carries its own
loop params (each with its own `Rep`) and their initial values,
structurally separating "runs once before the loop" from "the loop body
itself" -- something the old flat `isLoop` boolean + scattered
`RSelfTailCall` nodes couldn't express. `Compiler.RC2.Loop` now wraps a
self-tail-recursive function's body in one `RLoop` (reusing the
function's own top-level args unchanged, all `RBoxed` -- this stage
changes no behavior, only representation); `Compiler.RC2.Emit`'s
`declareLoopParam` skips declaring a loop param entirely when it's
simply an unchanged, already-in-scope function arg (the common case),
so generated C is unaffected.

Verified: generated C confirmed byte-for-byte identical to before this
change; 19/19 refc-suite tests and all smoke tests still match
`idris2 --cg refc`; benchmarks unaffected. Stage 2 (Compiler.RC2.
MutualLoop's own adaptation) is a separate, following commit; the
actual native-representation optimization this groundwork enables is
deliberately not part of either stage.

## 2026-08-13 -- Avoid a synthetic let for String and small-Integer constant operands

`RCConst` (no let-binding, no dup/drop, no C declaration) used to be
restricted to native-eligible literals. Widened it to also cover
`String` (always cheap: staged into a deduplicated static, see
`orStagen`) and `Integer` within the small-value cache range [0, 100)
(`idris2rc2_getSmallInteger`, an O(1) lookup, no allocation) -- both
already render just as cheaply read-in-place as a native literal.
Large/uncached `Integer` literals stay let-bound (computed once,
shared via dup/drop), since re-evaluating those parses/allocates a
fresh GMP integer every time. Extracted `boxedConstExpr` (the staging/
caching logic RPrimVal's own emission already had) so both call sites
share it.

Verified: generated C confirmed to inline constants directly (e.g.
`idris2rc2_sub_Integer(var_0, idris2rc2_getSmallInteger(1))`, no
separate temp/dup/drop); 19/19 refc-suite tests and all smoke tests
still match `idris2 --cg refc` byte-for-byte; benchmarks unaffected.

## 2026-08-13 -- Represent constructor-reuse's runtime check as IR (RReuseOffer)

The reuse-eligible-alt uniqueness check (`if (idris2rc2_isUnique(sc))
{...} else {...}`) used to be synthesized fresh by Emit.idr's
`emitReuseOffer` every time, computing its own dup/drop sets at
emission time -- the one remaining piece of new control flow Emit
invented rather than mechanically lowered. New `RReuseOffer` IR node
(replacing `RConAlt`'s `offersReuse` flag) lets Compiler.RC2.Reuse
encode the whole thing as data, including the exact dup-on-shared set;
Emit.idr now only ever renders a fixed template. Fixed a double-dup bug
this surfaced: `branchBody`'s own generic "destructured fields survive,
dup them" rule needed to recognize and skip a reuse-wrapped alt (which
already fully owns that dup on its own, conditionally) instead of
applying on top of it unconditionally.

Verified: generated C for `refc-suite/reuse` is exactly the expected
shape (no double-dup); 19/19 refc-suite tests and all smoke tests
still match `idris2 --cg refc` byte-for-byte; benchmarks unaffected.

## 2026-08-13 -- Add `--directive dumprcexp` to dump the final RCExp

New `Compiler.RC2.Pretty` renders the whole program's final RCExp
(after Reuse/MutualLoop/Loop -- exactly what Emit.idr consumes) as a
human-readable, indented text file, written next to the `.c` output as
`<outfile>.crexpr` whenever `--directive dumprcexp` is passed. Reuses
upstream idris2's own generic `--directive` passthrough (`session.
directives`, the same mechanism Chez/ES use for their own directives),
so this needed no changes to idris2-src.

## 2026-08-13 -- Drop braces/indentation from bare trailing case branches

Follow-up to the else-chaining removal: under `SinkReturn`, a case's
unconditioned trailing branch (formerly `else { ... }`) is now emitted
without its own `{ }` wrapper or extra indentation -- it's provably
always the last thing in its enclosing C block, so nothing needs the
tighter scope. Same for `emitCmpCaseInto`'s `whenFalse`.

## 2026-08-13 -- Drop redundant conditions/else-chaining in case codegen

Two related simplifications to `emitConCaseInto`/`emitConstCaseInto`
(new shared `emitAltChain`) and `emitCmpCaseInto`: a case with no
explicit default now skips the last alt's own condition check entirely
(coverage already guarantees it matches); and under `SinkReturn`, since
every branch is guaranteed to end in `return`/`goto`, alts no longer
need `else`-chaining at all. Together, a 2-alt case with no default in
tail position (e.g. a `Bool`-shaped match) collapses from
`if (...) {...} else if (...) {...}` to `if (...) {...} {...}`.

## 2026-08-13 -- Emit case branches straight into their real destination (Sink)

Generalized `assignInto` into a `Sink` (a variable, or `return`) so
`RConCase`/`RConstCase`/`RCmpCase` branches write directly into the
caller's real destination instead of a throwaway `switchReturnVar` that
gets copied afterward. Simplified `emitRC`'s `RAppName`/`RUnderApp`
cases too, now that `tryBuildClosureInto` always intercepts them first.

## 2026-08-13 -- Mutual tail recursion loop conversion (Compiler.RC2.MutualLoop)

Extends self-tail-call loop conversion to cycles of >= 2 mutually
tail-recursive functions. New whole-program pass merges each such
group (found via Tarjan's SCC) into one function dispatching on a tag,
with every internal transition rewritten as an ordinary self-tail-call
so `Compiler.RC2.Loop` converts it to a `goto` with no changes of its
own. Each original name becomes a thin wrapper.

## 2026-08-13 -- Self-tail-call loop conversion (Compiler.RC2.Loop)

A function's own self-recursive tail calls now compile to reassigning
parameter variables and a `goto`, instead of a closure + boxed
trampoline. `BenchLoop.idr` runs at ~68% of RefC's time (was ~90%).

## 2026-08-13 -- Fix remaining closure_N-then-copy redundancy; fix a real refcount leak it was hiding

`tryBuildClosureInto` now sees through `RLet` too, avoiding a
throwaway `closure_N` copy. Exposed and fixed a real leak: the
surrounding fallback re-ran `emitRC` on the un-peeled expression on
failure, double-emitting a wrapper's dup/drop/free.

## 2026-08-13 -- Remove keepBoxedLocals, confirmed dead code

Verified `RC.idr`'s `Owned` set never contains a Native local, so
`keepBoxedLocals`'s Emit-time re-filter could never remove anything.

## 2026-08-13 -- Avoid a synthetic let for zero-argument constructor operands

New `RCEmptyCon` `RCLocal` inlines a tagged nullary constructor as a
constant, no `var_N`/heap allocation. Fixed a segfault it surfaced:
`RConCase`'s dispatch needed `idris2rc2_conTag` to handle a scrutinee
that's now sometimes a tagged pointer, not always a heap constructor.

## 2026-08-13 -- Move numeric.c's one-line functions into numeric.h as static inline

Lets the C compiler inline them at call sites. Multi-statement
functions (`div_Integer`, string conversions) stay in `numeric.c`.

## 2026-08-13 -- Fuse native comparisons directly into two-way branches (RCmpCase)

A comparison feeding straight into a two-way Bool match compiles to a
raw C boolean in the `if`, skipping Idris2's boxed Bool encoding.

## 2026-08-12 -- Elevate constructor-reuse-in-place analysis to a dedicated IR pass

Moved constructor-reuse-in-place out of `Emit.idr`'s stateful map into
a new `Compiler.RC2.Reuse` pass, decisions encoded directly on the IR.

## 2026-08-12 -- Add cast-primitive coverage test for Double/Char/String

`Test7CastMatrix.idr` covers `Cast` combinations upstream's `integers`
test doesn't touch.

## 2026-08-12 -- Add CLAUDE.md

Repo layout, build/test commands, and conventions for future sessions.

## 2026-08-12 -- Elide dup/drop entirely for Boxed locals of always-tagged PrimTypes

`Int8`/`16`/`32`, `Bits8`/`16`/`32`, `Char` are always tagged pointers,
never heap allocations, so dup/drop/free on them were pure waste.

## 2026-08-12 -- Make ROp's operand-drop an explicit IR field instead of an Emit.idr rule

Added a `postDrop` field to `ROp`, decided once by `annotate`.

## 2026-08-12 -- Reduce unnecessary variable/statement generation in native codegen

Four incremental steps to cut generated-C noise for native arithmetic.

## 2026-08-12 -- Add native-int width/signedness test, fix a real refcount leak it found

`Test6NativeInts.idr` found a leak: Boxed operands of a native-result
op were never dropped in `emitNativeValue`'s `ROp` case.

## 2026-08-12 -- Implement System.Clock, with clock_gettime precision

Deliberately diverges from RefC's coarse `time()`-based implementation.

## 2026-08-12 -- Implement Data.Buffer

Ported RefC's raw byte-buffer primitives. Fixed a real bug: two FFI
tags expect different pointer unwrapping, which rc2 treated identically.

## 2026-08-12 -- Port upstream RefC regression tests, fix 6 bugs they surfaced

Ported 17 of `idris2-src`'s `tests/refc/*` programs into
`rc2/tests/refc-suite/`.

## 2026-08-12 -- Add explicit RDup/RFree reference-counting primitives to RCExp

`RDup`/`RFree` became first-class IR nodes alongside `RDrop`, replacing
the old per-use "borrowed" flag.

## 2026-08-12 -- Add rc2: independent external C code generator backend for Idris2

Initial implementation. A from-scratch external backend, diverging
from RefC in two ways: reference counting is a separate IR pass before
C emission (Perceus/Koka-style), and function-local numeric
intermediates get native type inference.
