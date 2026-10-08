# Dup/drop push-down (`Compiler.RC2.PushDown`)

## What this pass does

A run of `dup`/`drop` nodes that sits directly in front of a `case`
(`RConCase`, `RConstCase`, or an `RCmpCase` without a `postDrop`) is moved
into the head of every arm, and a `dup v` that then meets a `drop v` in the
same arm is cancelled. Before:

```
case v525 of
  CONS [..] args= [v524, _] ->
    dup v524
    drop [v525]
    case v524 of
      CONS [..] args= [v522, _] ->
        dup v522
        drop [v524]
        v522
      _ ->
        drop [v524]
        "none"
```

After:

```
case v525 of
  CONS [..] args= [v524, _] ->
    case v524 of
      CONS [..] args= [v522, _] ->
        dup v522
        drop [v525]
        v522
      _ ->
        drop [v525]
        "none"
```

The field `v524` is borrowed from its parent `v525`. `Reuse.resolveAlt` makes
every surviving field owned (`dup v524`) so that the parent can be dropped at
the head of the arm; the inner `case` then drops `v524` again on each arm.
Pushing the run into the arms lets the parent's drop wait until the arm is
entered and removes the field's `dup`/`drop` pair on that path. Disable with
`--directive nopushdown`.

The shape was found by `tools/rcexpr-lint --pushdown-stats` (pattern A, see
`tools/rcexpr-lint/README.md`). `RC.annotate` places dups at consumption sites only, so it is not the source.
Of the 8,535 places on idris2-lsp where only `dup`/`drop` nodes separate the dup
from the `case`, 6,161 are case fields (the shape `Reuse.resolveAlt` makes with
`dupOnSurvive` plus the arm's `outerDrop`) and 2,374 are not (by reading,
`LateInline` splicing a callee after the caller `dup`'d its argument, `Loop` and
`ConAltNative`; not verified by switching passes off). That is why the pass runs on the final IR
(right after dead-code elimination, before `DupMerge`) instead of inside
`annotate`: it sees every producer's output, and the IR the lint measures.

## Algorithm

`pushDownExp` walks the tree. At a maximal run `R` of `RDup`/`RDrop` nodes
followed by a `case` `K`:

1. `normalize R`: every `dup` first (counts merged per local), then one `drop`
   with what remains after cancelling matching `dup`/`drop` pairs.
2. For each arm `i` with leading run `Q_i`, `normalize (R ++ Q_i)`; the number
   of cancelled pairs is the saving of the arm.
3. Rewrite only if some arm cancels a pair and the static count of
   `dup`/`drop` operations does not grow:
   `sum_i |normalize (R ++ Q_i)| <= |R| + sum_i |Q_i|`, which is
   `(arms - 1) * |R| <= 2 * cancelled pairs`. Every path executes at least as
   few operations as before in any case; the static condition only keeps the
   code (and the `dup`/`drop` line counts) from growing.
4. Recurse into the new arms: the run at the head of an arm may now sit in
   front of the next `case` and move on (the nested-pattern shape above moves
   down every level).

Operations that are `reuseOffer`, `free`, `releaseReuse`, or anything that is not
a plain `dup`/`drop` end a run, so a uniqueness test never sees a changed count.

## Why it is sound

Within a run nothing is bound and nothing observes a count, so the run is a
multiset of `+1`/`-1` on locals plus an ordering constraint: a `dup` of a field
must happen while something still keeps the field alive.

- Moving a `dup` earlier is safe: fewer objects have died. Moving a `drop` later
  is safe: an object only lives longer. The canonical form `dups ++ drops`
  therefore never frees anything early, and in it a `dup v` and a `drop v`
  cancel whatever sits between them, including the `drop` of a parent that owns
  `v`.
- Delaying the whole run past the dispatch of `K` is safe: dispatch changes no
  count, and no drop has run when the `dup`s execute (the run is delayed as a
  unit, so a `dup` is never separated from the drop that its field depended on).
- A `drop` of something the dispatch reads (the scrutinee, a compared operand)
  is never delayed: the pass does not fire then. Neither does it fire for an
  `RCmpCase` with a non-empty `postDrop`, whose drops run before the arms.
- The cancelled pair is `dup v` against a `drop v` that the arm opens with, in
  the arm's own leading run. No `reuseOffer` of `v` is crossed (it ends the run),
  so a `reuseOffer v` arm keeps its `dup` and the parent-unique reuse path is
  unchanged.

What it deliberately does not cross: a `let` (a call between the run and the
`case` may consume a field's parent or keep a parent alive across a call that
relies on uniqueness; a delayed parent drop would silently turn an in-place
update into a copy), and a cancelling `drop` that sits deeper in the arm than
its leading run.

## Measurements (idris2-lsp, final IR, static counts)

Same compiler, `--directive nopushdown` against the default:

| | nopushdown | default |
|---|---|---|
| `dup` lines / `drop` lines | 78,483 / 71,191 | 74,835 / 64,999 |
| IR lines | 670,479 | 660,639 |
| all dup/drop operations | 269,416 | 255,574 (-5.1%) |
| pattern A (lint) places / operations | 12,277 / 19,255 | 5,065 / 5,057 |
| pattern D (field dup, then parent drop) places / operations | 19,410 / 29,584 | 13,421 / 20,827 |
| `rcexpr-lint` anomalies | 0 | 0 |

The pass takes about 0.13 s on idris2-lsp. What is left of pattern A is almost
entirely the shapes the pass refuses: a `let` or a `cmp` between the run and the
`case` (4,755 of the 5,065 places, mostly a call result that is then matched)
and arms that cancel deeper than their leading run.

## Pattern D: field dup, then the parent's drop (design only)

`dup f; ...; drop [P]` where `f` is a field of the case-matched `P` (lint
pattern D) is still 13,421 places / 20,827 operations (8.1%) on idris2-lsp after
the push-down, 9,914 of those operations inside loops. Both operations vanish if
`P` is unique at run time: the shell is freed and the fields' references simply
pass to their new owner. A static pass cannot know that.

The machinery exists already: `reuseOffer P dupOnShared=[fields]
dropOnUnique=[]` followed by `releaseReuse P` emits `if (isUnique(P)) { /* keep
the shell */ } else { dup fields; drop P }`, and `Reuse.resolveAlt` produces it
only when the arm goes on to build a constructor of the same name. Dropping that
condition for the remaining D sites is the cheapest option (no new IR node, no
`Emit` change); it trades one uniqueness test per site for the `2k` refcount
operations on the unique path, and costs code size. `resolveAlt` records a
measurement in the other direction (collapsing a dead offer to the shared path
added refcount traffic), so this needs a run-time measurement (`bench.sh`), not
static counts. Borrowing the field from the parent instead is the alternative,
and is on hold (TODO.md). Typed-constant fields (`noboolfield`) carry no
`dup`/`drop` and are not part of D.
