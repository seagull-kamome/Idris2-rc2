# Tail recursion modulo constructor (TRMC)

Status: phase 1 implemented (2026-09-26, `Compiler.RC2.Trmc`); phases 2-4
are tracked in `TODO.md` ("tail recursion modulo constructor").
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
2. All its recursive sites use the same constructor field index `k`.
   `::` always uses field 1. Differing sites are phase 3.
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
is the one to rewrite; the others stay ordinary calls. This is
phase 3.

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
   - Test95 covers `mergeBy`, `[1 .. n]`, `Data.Vect.map`, and a
     `filter` that mixes self tail calls with `::` sites, each at 1M
     elements, under valgrind.
   - Re-measure with the `scratchpad` `trmc` tool (sites left), the
     `sort` benchmark against Chez, and idris2-lsp's `--timing 3`.
2. **Phase 2:** mutual recursion. Apply the same rewrite over a
   MutualLoop group, with `res`/`last` added to the group's shared
   slots (36 `::` and 51 other sites).
3. **Phase 3:** differing field indexes (carry `k` as a native loop
   parameter) and multi-field sites (rewrite the last-evaluated call).
4. **Phase 4:** an optional raw hole address, if the refcount traffic
   on `last` shows up. Also constructor contexts (Koka's `ctx`) for
   difference lists, which is `TODO.md`'s "closure-valued loop
   parameters": represent `zs . (y ::)` as `(res, last)`, making
   composition and application O(1).

## Phase 1 results (2026-09-26)

**Correctness.** `Test95Trmc` builds lists and a `Link`/`End` chain of
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
