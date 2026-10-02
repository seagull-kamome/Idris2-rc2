# Tail recursion modulo constructor (TRMC)

Status: phases 1 to 3 implemented (2026-09-26 and 2026-09-27,
`Compiler.RC2.Trmc`); phase 4 was measured, dropped or done elsewhere (see "Plan"). What
remains is tracked in `TODO.md` ("tail recursion modulo constructor").
Motivation is in `KNOWN-BUGS.md` ("deep non-tail recursion overflows
the C stack").

## Problem

```idris
mergeBy order (x::xs) (y::ys) = case order x y of
    LT => x :: mergeBy order xs (y::ys)
    _  => y :: mergeBy order (x::xs) ys
```

The recursive call sits under `::`, so it isn't a tail call. Every
element costs one C stack frame. rc2 runs on the C stack (8 MB), so
`mergeBy` crashes at 100k elements, `[1 .. n]` (`takeUntil`) likewise,
and `sort` at 1M. Chez grows its stack and completes all of these.

Measured on idris2-lsp's final RCExp (`TODO.md` has the full table):
- 283 tail `::` sites have one recursive field;
- 365 more are on other constructors, mostly term traversals;
- 151 have two or more recursive fields.

## Idea: destination passing

Build the cell *before* the recursive call, with the recursive field
left as a hole. Then let the recursive call fill that hole instead of
returning. The recursive call becomes a tail call, and the existing
Loop conversion turns it into a loop.

Every cell is fresh (`RCon`) and unreachable from anywhere but the
chain under construction until the function returns. Writing into it
is therefore unobservable, the same argument as Perceus/Koka's TRMC and
this project's own `reuse=`.

## Shape of the rewrite

For an eligible function `f`, the pass emits two functions.

**`f#`** (`MN "rc2_trmc_<f>"`) is the accumulating version. Its
parameters are `f`'s parameters plus two more, `res` and `last`:
- `res` is the first cell of the chain, returned at the end.
- `last` is the cell whose hole is still open.

Both are ordinary owned `Boxed` locals. `f#`'s body is `f`'s body with
each tail rewritten:

| Tail of `f` | Tail in `f#` |
|---|---|
| recursive site: `let v = call f as'; C [.., v, ..]` | `let c = C [.., NULL, ..]; fill last.k := c; call f# as' res c` |
| plain self tail call `call f as'` | `call f# as' res last` |
| any other tail `e` | `let r = e; fill last.k := r; drop last; res` |
| `crash` | unchanged |

Here `k` is the hole's field index, which is static per function.

**`f`** keeps its name and signature, so no caller changes. Its body is
also `f`'s body, with only the recursive sites rewritten:

```
let c = C [.., NULL, ..]
call f# as' c c
```

All of `f`'s base cases return exactly as before, so a call that never
recurses costs nothing extra.

After Loop conversion, `f#` is a loop over the original parameters plus
`res` and `last`. Each iteration does one allocation (usually a
`reuse=` of the dying input cell), one field store, and one extra
refcount on the cell passed along as `last`.

### Several hole indexes (phase 3)

When the sites fill different field indexes, such as `Bind` and `App`
in one term traversal, `f#` takes a third extra parameter, `hk`: the
index of `last`'s hole. Each site passes its own index as a constant.
A fill becomes a `case` over `hk` with one static `RFill` per index:

```
case hk of
  0 -> let _ = fill last . 0 = c; call f# as' res c #1
  _ -> let _ = fill last . 1 = c; call f# as' res c #1
```

`RFill` itself keeps a static field, so no pass that knows it changes.
The code after the fill (a tail call, or returning `res`) has no
`let`s, so each branch gets its own copy of it. A function with a
single index gets no `hk`, exactly as in phase 1. `hk` is always small,
so Loop keeps it as a native loop parameter.

### Several recursive fields (phase 3)

Of a site such as `Node (f l) x (f r)`, only the last-evaluated
recursive call becomes the hole. The earlier ones stay ordinary calls
to `f` (the entry, which uses `f#` in turn). A tree map therefore loops
down its right spine and recurses only as deep as the tree's left
branches.

### Why `last` is an owned reference, not a raw hole address

A raw `Value **` hole would need a new non-refcounted `Rep`, which
every pass that matches on `Rep` would have to learn. Keeping `last`
as an ordinary owned `Boxed` reference leaves RC (`annotate`), Reuse,
Loop, DualABI and DeadVars unchanged.

The newest cell is held twice: once by the previous cell's field, and
once by `last`. RC inserts the `dup` itself, because `c` is both
consumed by `fill` and passed on as `last`. The old `last` is dropped
at its final use, `fill`'s `postDrop`. So every cell ends with a
refcount of 1.

The price is one increment and one decrement per element. A hole
address would save those, and can come later (phase 4) if it shows up
in benchmarks.

## New IR node: `RFill`

```
RFill : FC -> (cell : RCLocal) -> (field : Nat) -> (value : RCLocal) -> (postDrop : List RCLocal) -> RCExp
```

It evaluates to Unit, like `RStructSet`, and is always `let`-bound:
- It stores `value` into `cell`'s field `field` without dropping the
  old content, which is the `NULL` hole.
- It consumes `value`.
- It only borrows `cell`: `postDrop` drops `cell` when this is its last
  use, the same convention as `RStructSet`'s `postDrop`.

Emit lowers it to
`((IDRIS2RC2_Constructor *)cell)->args[field] = value;`.

Every pass that knows `RStructSet` gets a matching `RFill` case. That
is 12 files today (`grep -c RStructSet`). The cases that matter are:

- **RC (`annotate`):** `cell` is a borrowed operand with `postDrop`,
  and `value` is a consumed operand.
- **DeadVars/Sink:** `RFill` has an effect. It must never be removed
  as a dead `let`, never sunk into a branch, and never moved past
  another `RFill`.
- **DualABI:** `value` and `cell` are always `Boxed`, so `RFill` is
  never a native read.
- **Pretty, and rc2base's AST/Parser/Lint:** a `fill` line.

The hole itself is written as `RCNull` in the `RCon`'s argument list.
That is safe because nothing after this pass projects fields out of a
let-bound `RCon`:
- `RCConstCon` is only created by ConstFold, which runs earlier.
- `PushConRC` only uses the tag.

## Eligibility

A function `f` is rewritten when all of the following hold.

1. It is a `RCFun` with at least one *recursive site*. A recursive site
   is a tail `RCon C args`:
   - exactly one of whose `args` is a local bound (through any nest of
     `let`s) to a strict, saturated `RAppName f as'`;
   - that local is used nowhere else.
2. (Phase 1 only; lifted by phase 3.) All its recursive sites use the
   same constructor field index `k`. `::` always uses field 1.
3. The `C` of each site is a real heap constructor: arity ≥ 1, not a
   newtype, not one of the NULL-represented nullary ones.
4. No `let` evaluated between the recursive call and the `RCon` has an
   effect, meaning a `%World` operand, `RExtPrim`, a foreign call, or
   `RApp`. The rewrite evaluates those lets before the recursive call,
   which only reorders pure computations. A crash or divergence inside
   one of them now happens before the recursion's, and the result is
   the same.
5. The function is not `%foreign`, not a CAF, and not already a loop
   body produced by MutualLoop. Mutual recursion is phase 2.

When a site has two or more recursive fields, the last-evaluated call
is the one to rewrite; the others stay ordinary calls (phase 3). They are evaluated before it,
so they are not among the lets that eligibility 4 checks.

## Pipeline position

TRMC goes after "Arity raise (after early inline)" and before "CAF
memoization" and "RC annotate":

- **After ConstFold, PushCon, SpecClosure, SpecConstCon and Early
  inline**, so it sees the specialised clones, such as the 33 copies of
  `Data.Vect.map`. It also means no later pass folds a hole cell into
  a static constant.
- **Before RC annotate**, so RC places every dup/drop for `res`, `last`
  and the new cells. Reuse can then offer the dying input cell to the
  new `RCon`, which makes `map`-like functions work in place.
- **Before Loop conversion**, which runs after RC and turns
  `call f# ... res c` into an `RLoopContinue`.

A `notrmc` directive disables the pass, like every other stage.

## Cost and risk

- **Code size:** each rewritten function exists twice, as `f` and
  `f#`. That is 364 functions in idris2-lsp. Later passes can shrink
  `f` again: LateInline splices it, DeadCode drops an unused `f#`.
  Check idris2-lsp's build time and C size with `--timing 3`.
- **Per-element work:** one loop iteration plus one store, one
  increment and one decrement, instead of a C call, a return and a
  frame. It should be faster as well as safe; verify with a benchmark.
- **Evaluation order:** see eligibility 4.
- **`f#`'s result is not struct-returnable** (`res` is a parameter).
  `f` may lose struct return where its recursive tails used to be
  constructors. Measure; the stack-safety gain dominates.

## Plan

1. **Phase 1 (this document):** self recursion, one recursive field,
   one field index per function; `RFill`; the `notrmc` directive.
   - `Test113DeepRecursion/Trmc.idr` covers `mergeBy`, `map`, `zipWith`,
     count-up-to builders, a `Link`/`End` chain, and a `filter` that
     mixes self tail calls with `::` sites, each at 1M elements, under
     valgrind.
   - Re-measure with the `scratchpad` `trmc` tool (sites left), the
     `sort` benchmark against Chez, and idris2-lsp's `--timing 3`.
2. **Phase 2 (done):** mutual recursion. See "Phase 2 design" below.
3. **Phase 3 (done):** differing field indexes (`hk`) and multi-field
   sites (rewrite the last-evaluated call).
4. **Phase 4 (measured, not pursued):** an optional raw hole address,
   if the refcount traffic on `last` shows up. It does not; see "Phase 4
   measured, not pursued". Also constructor contexts (Koka's `ctx`) for
   difference lists, representing `zs . (y ::)` as `(res, last)`: done
   by `Compiler.RC2.ClosureCtx` (`closure-accumulator.md`).

## Phase 2 design: mutual recursion (2026-09-27)

### Shapes

Measured on idris2-lsp built with `--directive nomutualloop`, so that
MutualLoop has not merged anything yet. Take the tail constructors
whose last-evaluated field is a call to another function. In 65 of
them, the callee reaches back to the caller through tail calls and such
fields alone. Only these can become loops. They come in two kinds:

- **A function and its `case block` helper (19 `::` sites and a few
  others).** `buildDoLets`, `collectDefs`, `mergeStrLit`,
  `compressLefts`, `words`, `getOpts`, ... The helper builds
  `x :: f xs`, and `f` tail-calls the helper. The recursion is as deep
  as the list is long, so these can overflow the stack today.
- **A term traversal and a specialised `Maybe` `map` (38 sites).** For
  example, `substEnv`'s `CConCase` ends in `map (substEnv ..) mDef`,
  and that clone of `map` builds `Just (substEnv .. x)`. The recursion
  is only as deep as the term, but the rewrite handles it the same way.

The other 90 mutual sites cannot become loops. Their last-evaluated
call reaches back only through a non-tail call: `substEnv`'s `CApp`
ends in a `mapAppend` clone that calls `substEnv` for each head.

### Rewrite

Phases 1 and 3 treat "the function" as the only target of a site.
Phase 2 makes it a set, a *group*:

1. **Edges.** For every eligible function (a `RCFun` returning
   `RBoxed`, with parameters), collect:
   - its tail calls;
   - the callee of each hole candidate. That is the last-evaluated
     call bound to a field of a tail `RCon`, used once, with no
     unreorderable `let` after it: phase 3's rules, with any callee
     allowed.

   Only edges between eligible functions count.
2. **Groups.** A group is a strongly connected component of that graph
   (`MutualLoop.tarjanSCCs`) with at least one site. A one-member group
   is exactly the phase 1 and 3 case.
3. **Accumulators.** Every member `m` gets `m#`. Its parameters are
   `m`'s own plus `res`, `last`, and `hk` if the group's sites use more
   than one hole index. Every member takes the same extra parameters,
   including a member with no site of its own (`f` in the helper
   pattern), because the chain passes through it.
4. **Bodies.** A member's `m#` body is `m` with each tail rewritten as
   in phase 1, where "`f`" now means any member:
   - a site calling member `g`:
     `let c = C [.., NULL, ..]; fill last := c; call g# as' res c k`;
   - a tail call to member `g`: `call g# as' res last hk`;
   - any other tail: fill `last` with it and return `res`.

   The fill dispatches on `hk` over the group's indexes (phase 3).
5. **Entries.** Each `m` keeps its name and signature. Only its sites
   change, to `let c = C [..]; call g# as' c c k`. Its tail calls to
   other members stay calls to their entries, so no caller changes.

The `m#` functions now tail-call each other and nothing else in the
group. MutualLoop runs after RC. It merges them into one function, as
it does any mutual tail recursion, and Loop turns that into one loop.
Nothing downstream changes: `hk`, `res` and `last` are ordinary
parameters to MutualLoop's slot sharing.

### Why a group, not per-function rewriting

Rewriting `f` alone cannot help the helper pattern. `f`'s site calls
`g`, and `g` has no site that calls itself. Each accumulator must
continue into the *callee's* accumulator, so the whole cycle needs
accumulators at once.

### Costs and risks

- **Code size.** Every member is duplicated, including the 19 `Maybe`
  `map` clones. LateInline and DeadCode shrink what ends up unused, as
  in phase 1.
- **MutualLoop groups grow.** A merged `m#` group has one alternative
  per member. The entries are not part of it: each calls into one `m#`
  once.
- **Order of evaluation.** Unchanged from phase 1, eligibility 4, per
  site.
- **Members that already tail-call each other.** Their entries remain
  such a group, and MutualLoop merges them as before. The `m#` versions
  form a second, separate group.

### Test

`Test113DeepRecursion/TrmcMutual.idr` covers two cases, at a million elements each:
- a function and a helper that builds `x :: f xs` (the helper
  pattern);
- a chain through a second type, `Node Int Opt`, where `mapOpt` fills
  the recursive field of `One`, `Two` or `Three` at index 0, 1 or 2.
  With `mapE`'s own hole at field 1, the group's holes use indexes 0 to 2.

Both helpers are larger than Inline's threshold. A small helper is
inlined into its caller before this pass, and the pair becomes plain
self recursion. The same happens to `Maybe`'s own `map`: inlined, it
leaves a `case` inside the field, which no phase handles.

The expected output comes from Chez. The test must run clean under
valgrind, and overflow the C stack with `--directive notrmc`.

## Phase 1 results (2026-09-26)

**Correctness.** `Test113DeepRecursion/Trmc.idr` builds lists and a `Link`/`End` chain of
a million elements through `map`, `filter`, `zipWith` and
count-up-to builders, and runs clean under valgrind. With
`--directive notrmc` the same test overflows the C stack.
`Data.List.mergeBy` also merges two 1M lists now; before this pass it
crashed at 100k.

**idris2-lsp** (static counts from the final RCExp, using the same
measurement as `TODO.md`):

| Remaining sites | before | after |
|---|---|---|
| `::`, one recursive field, self | 247 | 10 |
| other constructor, one recursive field, self | 314 | 211 |
| mutual (phase 2) | 87 | 84 |
| two or more recursive fields (phase 3) | 151 | 133 |

- 59 `rc2_trmc_*` functions survive to the final program. The rest were
  spliced into their entry by LateInline or dropped as dead.
- 202 of the 211 remaining one-field sites on other constructors are
  in functions whose sites build several different constructors (`Bind`
  and `App` in one term traversal). Their holes sit at different field
  indexes, which phase 1 declines; that is phase 3.
- `rcexpr-lint` finds no anomalies in the dump.

**Build time.** The pass itself takes 0.1s on idris2-lsp. The
following stages together grow by about 0.3s (RC annotate +0.15s,
DeadCode +0.07s, ...).

**Speed.** A loop that maps, filters and sums a 50k-element list 200
times runs in 3.19s instead of 3.47s (-8%). Peak RSS falls from
10.0 MB to 6.7 MB, because the recursion no longer uses the stack.

**Still crashing at 1M elements** (`KNOWN-BUGS.md`): `sort`, because of
`splitRec`'s closure accumulator (phase 4 / `TODO.md`). `[1 .. n]` also
crashed, in the runtime's recursive teardown; that is fixed separately.

## Phase 3 results (2026-09-27)

**Correctness.** `Test113DeepRecursion/TrmcHoles.idr` covers:
- a million-long chain alternating `A Int Alt` and `B Alt Int` (holes
  at fields 1 and 0);
- a map over a million-deep right spine of a tree, with the left
  subtree an ordinary call;
- the same map over a small balanced tree.

Its output matches Chez's, and it is clean under valgrind. With
`--directive notrmc` it overflows the C stack.

**idris2-lsp** (same measurement as phase 1; both columns built from the
same tree, with only `Trmc.idr` differing):

| | phase 1 only | with phase 3 |
|---|---|---|
| functions with a remaining site | 108 | 94 |
| of which self recursion only | 50 | 15 |
| sites, one recursive field | 305 | 130 |
| sites, two or more recursive fields | 133 | 52 |
| sites whose fields call only `f` itself | 329 | 27 |
| sites with a field calling a function that calls `f` back | 109 | 155 |
| `rc2_trmc_*` functions in the final program | 59 | 97 |

- The self sites left are ineligible. For example, `addLocs` reads
  the recursive result again to build the head.
- The rest involve mutual recursion (phase 2). 46 sites moved from
  the self to the mutual row. `substEnv`'s `CApp` is one: its
  last-evaluated field maps over the argument list through a
  specialised `mapAppend` that calls `substEnv` back, so phase 3 cannot
  make the self call the hole. Why the measurement counted it as self
  recursion before phase 3 was not tracked down.
- `rcexpr-lint` finds no anomalies. The pass still takes 0.12s.

## Phase 2 results (2026-09-27)

**Correctness.** `Test113DeepRecursion/TrmcMutual.idr` matches Chez's output and runs
clean under valgrind. With `--directive notrmc` it overflows the C
stack. In its dump, both pairs end up as one MutualLoop loop that
dispatches on the member tag and on `hk`.

**idris2-lsp** (same measurement as phases 1 and 3):

| | phase 3 | with phase 2 |
|---|---|---|
| functions with a remaining site | 94 | 57 |
| sites | 182 | 104 |
| sites with a field calling a function that calls `f` back | 155 | 77 |
| `rc2_trmc_*` functions in the final program | 97 | 100 |

The design predicted 65 of the mutual sites; 78 went. `rcexpr-lint`
finds no anomalies.

**Build time.** The pass went from 0.12s to 0.51s on idris2-lsp:

| Stage | Time |
|---|---|
| sites | 0.13s |
| call graph | 0.10s |
| SCCs | 0.13s |
| groups | 0.04s |
| rewrite | 0.02s |

The graph and SCC stages are new; finding sites now considers calls to
any function, not only to `f`. A first version fed every function to
Tarjan and took 0.60s. The graph now leaves out self edges and
functions without an edge to another function, since a one-member
group needs no SCC.

## Phase 4 measured, not pursued (2026-09-27)

**A raw hole address instead of an owned `last`.** It would save one
`dup` of each new cell and one `drop` of the previous one. The saving
was measured without implementing it:
- the generated C of a benchmark that maps and filters a 1M-element
  list 50 times was edited by hand, deleting `last`'s `dup`s and
  `drop`s in both TRMC loops (entry, each site, each finish);
- the edited program ran clean under valgrind, with the same memory
  still in use at exit as the original.

It ran in 27.33s instead of 27.39s (0.3%). Both counts touch a cell
that was just written and is still in cache, so they are cheap. The
cost of these loops lies elsewhere: Chez runs the same benchmark in
7.4s. perf puts most of rc2's time on loading the input cells'
refcounts (cache misses) and on atomic `dup`/`drop` of their fields,
plus `malloc`: the input list is shared, so `map` cannot reuse its
cells.

**A hole under a `case` in a field** (`Node x (case m of .. Just (f
e))`, left by inlining `Maybe`'s `map`) occurs 3 times in idris2-lsp.
Not worth a pass.

## Bugs found

1. **LateInline aliased two parameters onto one caller local.**
   `mergeBy xs xs` passes the same local twice. Once TRMC made
   `mergeBy`'s entry non-recursive, LateInline could splice it, and
   `buildSplice` aliased both parameters onto that one local. The two
   `reuseOffer`s then shared one reservation, and two new cells were
   built in the same storage, so `mergeBy xs xs` returned a truncated
   list. `buildSplice` now binds a fresh local for a parameter whose
   argument also appears later in the same call, as it already did for
   a loop-carried parameter.
2. **`where`-bound sets in `applyTrmc`.** The pass first took 20s on
   idris2-lsp. The set of newtype constructors was bound in `where`,
   so it was rebuilt for every definition (the "`where`-clause trap"
   in `constant-constructor-specialization.md`). Binding it with
   `<- pure` brought the pass down to 0.1s.
3. **Reuse offered a field-less constructor.** Phase 3's tree test
   crashed in `mapT f Leaf = Leaf`, with or without TRMC. Reuse
   offered the scrutinee's cell to the `Leaf` built in that branch, so
   Emit called `idris2rc2_isUnique` on it. But a folded constant holds
   `Leaf` as a tagged pointer (`RCEmptyCon`), not a cell, and reading
   its refcount faulted. A field-less alternative has nothing worth
   reusing, so `Reuse.resolveAlt` no longer offers one.
4. **ConstFold left a `case` over a folded `Nothing`.** Phase 2's test
   failed to compile, with or without TRMC: an undeclared C local in
   `case v of Nothing -> ..`. After Inline, a `case` read the `Nothing`
   field of a pair that ConstFold had folded. The field's local
   resolved to `RCNull`, which the `RConCase` case had no clause for.
   So the `case` kept naming the local, whose `let` was gone from the
   output. Which pass dropped it was not tracked down. A `NULL` scrutinee now selects the alternative of
   `Nil`, `Nothing`, `Z` or `MkUnit`, whichever the `case` has.
