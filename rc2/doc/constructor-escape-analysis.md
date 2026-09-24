# Constructor escape analysis: dropping constructors that never escape

**Status:** rewrites A and B, the known-partial fold, and early
inlining of loop-free single-caller callees implemented (2026-09-25).
An RC-aware fold after `LateInline` for what it still creates is
designed, not implemented; tracked in `TODO.md`.

## The problem

A constructor built in a function and then only pattern-matched in
that same function never needed a heap cell. The cell is allocated,
its tag and fields are written, `case` reads them straight back, and
the cell is dropped (or offered for reuse) -- all within a few lines of
IR. rc2 currently removes this only when every field is a compile-time
constant (`Compiler.RC2.ConstFold`'s `RConCase` scrutinee resolution,
`rc2/doc/const-caf-fold.md`). A constructor holding any variable field
is left as is.

Upstream Idris2 folds a `case` on a known constructor at the `CExp`
level, before rc2 sees the program. The shapes below are created
afterwards, by rc2's own inlining (`Compiler.RC2.Inline`,
`Compiler.RC2.LateInline`) and ANF conversion, so upstream's fold never
sees them.

This is not about constructors returned to a *caller* and matched
there; that needs a calling-convention change and is tracked
separately in `TODO.md` ("return small constructors by value").

## Measurements (idris2-lsp, whole-program `dumprcexpr`, 2026-09-25)

Counted on the final IR with awk scripts over the dump (not checked
in). RC operations (`dup`, `drop`, `reuseOffer`, `releaseReuse`,
`reuse=`) are ignored when classifying a local's uses, since they are
bookkeeping around the construction, not uses of its value.

**Shape A -- a local bound directly to `con`, later `case`-matched in
the same function:** 1,819 locals in 1,036 functions.

| constructor | count | no use other than the `case` |
|---|---|---|
| `Prelude.Types.Right` | 1,625 | 1,625 |
| `Just` | 146 | 143 |
| `::` | 36 | 34 |
| other records | 12 | 9 |

1,792 of them are the tightest form: `case v of` immediately follows
the `let`, and `v` has no other use. With `--directive nolateinline`
the count is 1,590 (1,498 `Right`). So about 87% exist before
`LateInline` runs, and about 230 are created by it.

The dominant source is upstream's `Core a = IO (Either Error a)`. Once
`pure`/`coreLift`/`>>=` are inlined, a `Right x` is built and then
matched on the next line:

```
let v54372 = (let v54373 = readIORef ... in con Right [v54373])
case v54372 of
  Left  [v54374] -> ...            -- unreachable
  Right [v54375] -> ... v54375 ...
```

**Shape B -- a local bound to a `case` whose arms end in constructors,
then immediately `case`-matched:** 2,354 `let v = case ...; case v of`
pairs. In 59 of them every arm ends in a constructor or constant. In
1,772 more, some arms do and some don't. This is the `Core` `do`-block
chain one level up. Each bind's inner `case` propagates `Left e` as
`con Left [e]` and finishes with `con Right [...]` on success, and the
outer `case` immediately takes the value apart again. In the dump,
the TTC decoder that builds a `Core.Context.MkTransform` out of five
successive `fromBuf` calls is a clear example. `Compiler.RC2.Inline`'s case-of-case collapse
(`tryCaseOfCase`, `rc2/doc/inlining.md`) doesn't fire on these. It
requires *every* inner arm to be constructor-headed, and the success
arm's head is a `let`/`case` chain that only *ends* in a constructor.

Bool-like `RConstCase` consumers show up in the same way (a `let v =
case .. of 1 -> x; 0 -> 0` followed by `case v of 1 -> ..; 0 -> ..`).
They are included in shape B.

## Escape classification

For a local `v` bound by `RLet`, before RC annotation (so no
`dup`/`drop` exists yet), every occurrence of `v` is one of:

- **scrutinised** -- the scrutinee of an `RConCase` (or `RConstCase`
  for a constant-valued `v`). This reads the tag and fields and does
  not let the value outlive the function.
- **escaping** -- anything else: an argument of `RAppName`/`RApp`/
  `RUnderApp`/`RCon`/`ROp`/`RExtPrim`/`RStructSet`, or a tail-position
  `RV v` (returned to the caller). Any of these may retain the value,
  so the cell must exist.

`v` **does not escape** if all of its occurrences are scrutinised. It
**partially escapes** if some are scrutinised and some escape. Only 8
of the 1,819 shape-A locals partially escape, so "does not escape" is
the case that matters.

The analysis is per-function and needs no interprocedural information:
passing `v` to a callee counts as escaping, without asking what the
callee does with it.

## Rewrite A: known-constructor fold (in `ConstFold`) -- implemented

`ConstFold`'s `Env` already maps a local to a constant form
(`RCConstCon` etc.) and resolves an `RConCase` whose scrutinee resolves
to one. Rewrite A adds three things to it (`ConstFold.idr`'s `Env` and
`UseInfo`):

- `uses`: the escape classification above, computed by `useInfo` in one
  walk over the definition before it is folded. Besides `escaping` it
  records `natives` (locals bound with a native `Rep`) and `boxedUses`
  (locals read somewhere only a Boxed value can go: call, closure and
  constructor arguments, `RV`, `RExtPrim`/struct operands).
- `knownCons`: a non-escaping local bound to `RCon n ci tag args
  Nothing`, with its (already resolved) field locals. A let chain
  ending in the constructor, `let v = (let a = e in con K [a])`, is
  flattened first so `a` stays in scope for the body. This is the usual
  shape, since ANF puts the field computations inside the value.
- `aliases`: a folded-away field id mapped to the local it was built
  from. `resolveLocal` consults it before the constants, so every later
  operand position sees through it.

An `RConCase` on a known local picks the alt by tag (by name for an
untagged constructor), binds its fields, and folds the alt body in
place of the whole `case`. Once no occurrence of the local remains, the
`RLet` goes, so the constructor is never built.

**Only non-escaping constructors are folded.** The first version also
folded the `case`s of a partially escaping local and kept the `RLet`
for the escaping uses. That was worse, not better, when a field was
native. Say `v` is built from a native `Int` `a` and escapes on one
path. The constructor still boxes `a` once, the fields that used to
share that box now read `a` directly, and each of their Boxed uses
boxes `a` again. `idris2rc2_mkInt64` allocates outside 0..99, so that
is one extra allocation per use. Partial escape is 8 of 1,819 locals
in idris2-lsp, so excluding it costs nothing measurable.

**Native fields read as Boxed are boxed once.** The same effect exists
without any escape. A native field read as Boxed in two separate
`case`s on the same local would be boxed twice, where the constructor
boxed it once and both reads shared that box. Seen in
`tests/BenchKnownCon.idr`, whose `mod` worker takes its first argument
Boxed. So a field is aliased to its argument only if the argument is
not native or the field is never read as Boxed. Otherwise:

- If the constructor has exactly one native field (`Just`/`Right` --
  the common case), the constructor's own local is reused as that
  field's box. The `RLet v = con K [a]` becomes `RLet v = RV a` (Boxed,
  so a boxing) and every Boxed-read field at that position aliases `v`.
  One box, shared, exactly as before, minus the constructor cell.
- Otherwise each such field gets its own `let field : Boxed = RV a` in
  its alt. Still no worse than before per `case`, since the constructor
  would have boxed `a` too.

Reusing the local as the box means it can no longer be scrutinised as a
constructor, so every `case` on it must fold. It always does for a
well-typed program. A field-count mismatch between constructor and alt
therefore becomes an `RCrash` instead of falling back to the `case`,
and a constructor with a `BI` literal field is never registered (a
`BI` must keep a real `RCLoc` for ownership, see `const-con-fold.md`'s
Bug #2).

**Only in the first fixpoint round.** `foldConstProgram` refolds every
definition on every round (five on idris2-lsp), and the `useInfo` walk
per definition per round took ConstFold from 0.78s to 2.29s. Later
rounds only substitute newly-constant CAFs, which seldom leaves a
constructor newly non-escaping, so they skip it: 1.20s. The clones
`Compiler.RC2.SpecClosure` folds (closure specialization and, through
`foldConstDefWith`, SpecConstCon) always get it. `--directive
noknowncon` turns it off in the fixpoint for A/B comparison.

### Measured (2026-09-25)

idris2-lsp, `--directive noknowncon` vs on:

| | off | on |
|---|---|---|
| shape A (`let v = con`, later `case v of`) | 1,784 | **166** |
| `con` nodes in the final IR | 62,788 | **59,570** (-5.1%) |
| `case` nodes | 49,824 | **48,167** |
| `dup` / `drop` | 94,116 / 77,708 | 92,317 / 76,142 |
| `reuse=` | 22,159 | 20,479 |
| IR lines | 735,274 | 717,609 (-2.4%) |
| compile time (median of 3) | 27.71s | 27.87s (+0.6%) |

`reuse=` drops because many of the removed constructors were the reuse
source for the next one (a `Left e` re-wrapped from the `Left e` it
matched). That cell is now never allocated in the first place.

The 166 left are mostly created by `LateInline` after RC annotation,
where this pre-RC fold can't reach (see "Pipeline placement").

`tests/BenchKnownCon.idr` (5 runs each): 3.51s off, 3.33s on (about 5%
faster). The loop body allocates a `Just` and a box per call without
the fold, and only the box with it.

## Rewrite B: pushing the consumer into the producer's tails -- implemented

`Compiler.RC2.PushCon`, a stage of its own right after ConstFold
(`--directive nopushcon` to disable). For `RLet v value (RConCase v
alts def)` (or `RConstCase`) where the `case` is the whole body, `v`
is read nowhere in the alts, and `value` has at least two tails:

1. Find `value`'s **tails**. A tail is where `value`'s result is
   produced: through `RLet`'s body, every arm of
   `RConCase`/`RConstCase`/`RCmpCase`, and nothing else.
2. Work out where each tail **lands** on the consumer:
   - `t` is `RCon K args` (reuse-free, as always pre-RC), `RV` of an
     `RCConstCon`/`RCEmptyCon`, or for an `RConstCase` consumer a
     constant: the alt it selects (or the default).
   - `t` is `RCrash`: nowhere; `t` stays as is.
   - otherwise (an unknown value, e.g. a call's result): the whole
     consumer.
3. Replace each tail `t` by `RLet v' t <what lands there>`, with a
   fresh `v'` and the landed part freshly renamed. For a known
   constructor that is a single-alt `case v' of K ...`, which
   rewrite A folds away. The stage refolds each changed definition
   with `foldConstDef` itself, so no later ConstFold run is needed.
   For a known constant the alt body goes in directly.
4. The outer `RLet v` disappears; `value`, rewritten, takes its place.

This is case-of-case where the inner `case`'s arms don't have to be
constructor-*headed*, only constructor-*ending*. Inline's `Lifted`
version requires the former and so misses the `Core` chain.

Leaving the field binding to rewrite A, rather than renaming fields
here, means B inherits its native-field rule ("boxed once") for free.

**Code size.** Each consumer part is copied once per tail that lands on
it, and an unknown tail lands *every* part. The typical `Core` chain
costs almost nothing. The inner `case` has N `Left`-propagating tails
and one `Right` tail, so the consumer's small `Left` alt is copied N
times and its large `Right` alt exactly once. The rewrite is skipped
unless all of these hold (`pushOk`):

- at least one tail is known, so something actually folds;
- no part larger than `bigAltThreshold` (24, as Inline's
  `smallBodyThreshold`) lands more than once, so a chain can't compound
  multiplicatively. That is the failure mode `rc2/doc/inlining.md`'s
  "Size budget" documents for the `Lifted` version;
- the total landed size is at most the consumer's own size plus
  `pushSizeBudget` (200, as `caseOfCaseSizeBudget`).

**Fresh ids.** Every copy gets fresh ids for everything it binds
(`LateInline`'s `collectBoundIds`/`freshenBoundIds`, exported for this,
and `Loop`'s `renameRCExp`), because later passes assume ids are unique
per definition. That needs the `VarId` counter, so this runs in `Core`,
not inside the pure `foldConst`. Consuming ids shifts later variable
numbers in generated C. One refc-suite test that greps generated C
(`callingConvention`) had its expected output renumbered for exactly
that.

**Order.** Bottom-up: a consumer that ends up at a tail sits in tail
position of the enclosing `value`, already rewritten.

### Where the allocation goes

A pushed tail's constructor is never built. Whether that removes a
`malloc` depends on what building it cost:

- **The constructor's cell.** If `Compiler.RC2.Reuse` would have built
  it in a cell just freed by the inner `case` (`Left e` re-wrapped from
  the `Left e` it matched), there was no `malloc` to save. The cell is
  now freed instead of recycled. Only a freshly allocated one is
  saved.
- **Its fields' boxes.** A native field has to be boxed to go into a
  constructor (`idris2rc2_mkInt64` allocates outside 0..99). Pushed,
  the value stays native all the way to the consumer's use. In the `Core`-shaped
  chain the final `Right (a + b)` is exactly this. Its cell was
  reused, but its sum was boxed.

The first draft of `tests/BenchPushCon.idr` showed no difference in
`malloc` count because both were already free there. Its fields came
from calls (already Boxed) and every cell was reused.

### Measured (2026-09-25)

idris2-lsp, `--directive nopushcon` vs on (both with rewrite A):

| | off | on |
|---|---|---|
| shape B (`let v = case ..; case v of`) | 2,327 | **1,625** (-702) |
| `con` nodes in the final IR | 59,570 | 60,475 (+905) |
| IR lines | 717,609 | 720,428 (+0.4%) |
| stage time | -- | 0.22s |

`con` nodes go *up* statically: the small alts are copied into every
tail. Any one run still goes through only one of the copies, and the
constructor it replaced is no longer built on that path. Static counts
can't show the dynamic effect, and idris2-lsp can't be run under rc2
(its FFI isn't resolvable), so the runtime evidence is the benchmark.

`tests/BenchPushCon.idr`: valgrind over 100,000 iterations counts
1,999,977 allocations off and 1,899,992 on, one fewer per call (the
sum's box). Wall clock over 5,000,000 iterations, 5 runs: 3.54s off,
3.45s on (about 2.6% faster).

Of the 1,625 left, about half are created by `LateInline` after RC
annotation (1,232 of the 2,327 exist with `--directive nolateinline`),
where this pre-RC stage can't reach. The benchmark shows the same
thing: `check1`/`check2` are spliced into `score` by `LateInline`, and
the `let v = if .. then Left .. else Right ..; case v of` each one
leaves behind is still there. Those tails allocate fresh, so they are
the more valuable half.

## Pipeline placement

| where | what | why there |
|---|---|---|
| inside `ConstFold` (first fixpoint round only, plus the clones SpecClosure folds) | rewrite A (implemented) | Cheap: extra maps in the existing walk, plus one use walk per definition. Removes most of shape A before SpecClosure, SpecConstCon and RC annotation ever see it, so they process less. |
| `Compiler.RC2.PushCon`, right after `ConstFold`, before `SpecClosure` (`nopushcon` to disable) | rewrite B (implemented), then a `foldConstDef` over each changed definition | Needs `Core` for fresh ids. Folding the result once more lets rewrite A and the constant folds act on the fields B just exposed. |
| after `LateInline` (later phase) | an RC-aware version of A/B for what LateInline creates: 166 shape-A sites, and about half of the 1,625 shape-B ones | See below. |

Doing the bulk pre-RC, then a separate cleanup after LateInline, is
the right split. `LateInline` splices already-annotated bodies (it
renames them and runs `stripOwnership`; see its module doc), so
everything it creates is post-RC. The shapes there carry
`dup`/`drop`/`reuseOffer`, and removing a construction must rebalance
them:

- The construction consumed one owned reference to each field arg.
  The matching alt `dup`s the fields it reads and drops `v`, which
  drops every field once. Net: the alt body owns exactly the fields it
  reads, and a field bound to `_` must get an explicit `drop` of its
  arg instead.
- A `reuseOffer v` in the alt goes away. A later `con ... reuse= v`
  becomes a fresh allocation, which costs the same as today (the cell
  it was reusing no longer exists), so the saving there is the `case`
  and the uniqueness check, not the allocation.

That is more machinery, so it is a separate, later phase. Its tails
allocate fresh more often than the pre-RC ones do (see "Where the
allocation goes"), so it is likely worth it.

## The shapes `LateInline` creates -- (2) implemented

With rewrites A and B on, idris2-lsp:

| | `--directive nolateinline` | normal |
|---|---|---|
| shape A | 22 | 166 |
| shape B | 503 | 1,625 |

So nearly all of what was left came from `LateInline`. It splices a
single-caller callee whose body ends in constructors right where the
caller matches the result, but after RC annotation, where A and B can't
reach. Two ways were considered:

- **(1) An RC-aware fold after `LateInline`**: A and B on annotated IR,
  rebalancing every `dup`/`drop`/`reuseOffer`/`releaseReuse`/`reuse=`
  around the construction and the alt, and inserting boxes by hand
  since Reps are final by then. A mistake is a leak or a double free.
- **(2) Inline loop-free single-caller callees before RC annotation.**
  `LateInline` runs after `Loop` only for callees that are recursive
  until `Loop` converts them. Of the definitions it removes from
  idris2-lsp (about 11,800), about 1,700 contain a loop.

(2) is implemented, as `Compiler.RC2.Inline`'s Criterion B
(`inlining.md`, "Criterion B at `Lifted`"). Two findings came with it.

**Criterion A duplicated arguments.** Splicing substituted argument
expressions for their parameters, so `sq (expensive y)` computed
`expensive y` twice. Non-atomic arguments are now `let`-bound first,
for both criteria.

**Partial applications are the closure analogue of rewrite A.** Once
`unsafePerformIO` (single caller: `main`) was inlined at `Lifted`, its
lifted lambda appeared as `partial f missing=1 [act]`, applied to the
world straight away. That `apply` stayed a boxed closure dispatch
(Test87 caught it). ConstFold now treats a non-escaping local bound to
an `RUnderApp` as it treats a known constructor. `escaping` no longer
counts being the closure an `RApp` applies. Each `RApp` of the local
with exactly the missing argument count becomes `RAppName f (captured
++ args)`, and one with fewer becomes a smaller `RUnderApp`. Once
nothing reads the local, the closure is never allocated. This also
fires well beyond the case that prompted it: idris2-lsp's `apply` count
dropped 11% (see below).

**Neither fold nor Criterion B works inside a CAF.** A direct call
where there used to be a closure dispatch let `LateInline` splice
`main`'s whole body into the memoized `__mainExpression` CAF. Later
passes optimised it less there: its arithmetic stayed Boxed, and
DualABI no longer inlined the FFI call `callingConvention` checks. So
`foldConstDef` doesn't fold known constructors or partials in a
0-argument definition, and Criterion B isn't applied in one.

### Measured (2026-09-25)

idris2-lsp, before this step vs after:

| | before | after |
|---|---|---|
| `apply` | 11,326 | **10,039** (-11%) |
| `partial` | 16,448 | **15,788** |
| allocating `con` (no `reuse=`) | 39,741 | **38,257** |
| `dup` / `drop` | 92,764 / 76,253 | 92,136 / 75,857 |
| definitions | 26,033 | 25,556 |
| IR lines | 720,428 | 711,725 (-1.2%) |
| shape A / shape B | 175 / 1,625 | 311 / 1,787 |
| compile time (median of 3) | 27.9s | 29.3s (+5%) |

Shapes A and B go *up*: calls that were closure dispatches are direct
now, so `LateInline` splices more, and some of that splicing forms
new shapes after RC annotation. Only 3,158 callees qualify at
`Lifted`, against `LateInline`'s ~11,800. The likely reason, not
verified, is that most of the latter become single-caller only after
ConstFold and SpecClosure turn closure applications into direct calls;
if so, what's left for (1) is not only loop-bearing callees.

`tests/BenchPushCon.idr`: `check1`/`check2` are now inlined at
`Lifted`, so their constructors meet the pushed `case` before RC and
fold away too. valgrind, 100,000 iterations: 1,999,976 allocations
with `nopushcon`, **1,500,052** with everything on. Wall clock over
5,000,000 iterations, 5 runs: 3.42s with `nopushcon`, **2.80s** on
(about 18% faster). Before this step the same benchmark took 3.45s.

## Correctness notes on rewrite B

- **`RCNull` tails** are treated as unknown: it is not a constructor
  tag PushCon can match on.
- **Laziness.** `RCon` has no `lazy` field, and the consumer only moves
  *after* `value`'s computation (to its tails), never before it, so
  evaluation order is preserved.
- **`RMemoize`** doesn't exist yet at this point (`insertMemoize` runs
  after SpecConstCon), so it needs no handling.

## Tests and benchmarks

- `tests/Test88KnownConFold` covers rewrite A (`bump`: two matches on
  one non-escaping `Just` with a native field; `keep`: a matched `Just`
  that is rebuilt and returned), with a `verify.sh` assertion that
  `bump` builds no `Just`. Its `score` is rewrite B's case (an
  inlined `Either` bind chain matched straight away), with an assertion
  that the chain result is never built. `useHalf` and the `M`-monad
  chain are output-only: they reach shape B only after `LateInline`
  or, through closures, never.
- `tests/BenchKnownCon.idr` and `tests/BenchPushCon.idr` measure the two
  rewrites (numbers above). An `M` monad over `IO (Either String a)`
  with an `%inline` `io_bind`-based bind was tried first as B's
  benchmark and doesn't reproduce idris2-lsp's shape: its
  continuations stay lambda-lifted closures, so no constructor and
  `case` ever meet in one function.
