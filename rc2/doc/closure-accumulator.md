# Closure-valued loop parameters -- design

Status: design, not implemented (2026-09-26). Tracked in `TODO.md`
("closure-valued loop parameters"). Builds on `trmc.md`, whose `RFill`
node and `res`/`last` pair this reuses.

## Problem

`Data.List.sortBy` splits its input with a difference list:

```idris
splitRec (_::_::xs) (y::ys) zs = splitRec xs ys (zs . ((::) y))
splitRec _          ys      zs = (ys, zs [])
```

After inlining `(.)`, each step builds one closure
`partial L missing=1 [y, zs]`, where `L x = zs (y :: x)`. The
`sortBy` caller starts `zs` at `id`. Loop conversion turns
`splitRec` into a loop that carries `zs`, but the final `zs []` runs
the whole chain: each `L` applies the previous closure before
returning. That is one non-tail C call per element, n/2 deep for a
list of n. `sort` of 1M elements overflows the C stack (`KNOWN-BUGS.md`,
"deep non-tail recursion").

## What the loops look like

idris2-lsp's final RCExp has 10 loops whose parameter `c` is updated
with a partial application capturing `c` itself (`TODO.md`). By the
body of that lambda `L` (argument `x`):

| Shape of `L x` | Examples | Count |
|---|---|---|
| `c (C .. x ..)`: `c` applied to a constructor with `x` in one field | `sortBy`'s `splitRec` | 1 |
| `c (e x)`: `c` applied to an arbitrary pure expression | `Data.Vect.foldr`'s `foldrImpl` (`go . f x`) | 1 |
| continuation passing: `L` calls the traversal again and wraps its result | the three `treeToList'`, the scheme backends' `applyLams` | 6 |
| other | `mkClosedElab`, `ProcessData.shaped` | 2 |

This design covers the first shape: the difference list. It is the
idiom behind the `sort` crash, and it is the one that maps directly
onto `trmc.md`'s machinery. The second shape is sketched under
"Later" below; the others are out of scope.

## Idea: the difference list is a constructor context

Write `zs_0 = k` for the closure the loop starts from, and let each
step `i` extend it with `(y_i ::)`:

```
zs_n v = zs_(n-1) (y_n :: v) = ... = k (y_1 :: y_2 :: ... :: y_n :: v)
```

So `zs_n` is `k` composed with the chain `y_1 :: ... :: y_n :: _`,
which has a hole at the end. That chain is what TRMC builds:
- `res` is the first cell;
- `last` is the cell whose tail is the hole.

The operations become:
- **Extending by `(y ::)`:** allocate `y :: NULL`, fill `last`'s hole
  with it, and make it the new `last`. That is O(1) and one allocation,
  instead of one closure.
- **Applying to `v`:** fill `last`'s hole with `v`, then compute
  `k res`. That is O(1) and uses no stack, instead of n nested calls.

`k` does not change during the loop. When `k` is `id` (the `sortBy`
case), `k res` is just `res`.

## Shape of the rewrite

It uses the same entry/twin split as `trmc.md`. The pass looks at a
function `f` before RC and finds a parameter `c` that meets all of
these:

1. **Every self tail call** passes `c` either unchanged or as
   `partial L missing=1 [caps.., c]`, with `c` captured exactly once.
2. **`L`'s body** is `let cell = C [..]; apply c' [cell]`.
   - `c'` is `L`'s own parameter bound to the captured `c`.
   - `L`'s argument `x` is exactly one field `k` of `C`, a heap
     constructor as in `trmc.md`'s eligibility 3.
   - Every other field of `C` is a capture or a constant.
   - `C` and `k` are the same for every such `L` used on `c`.
3. **Every other use of `c`** in `f` is a saturated `apply c [v]`.
   There is at most one on any path, and `c` is not used after it.
   `c` never escapes: it is not passed to another function, stored or
   returned.

`f` becomes an entry plus an accumulating twin
`f# = MN "rc2_ctx_<f>"`, which takes `f`'s parameters plus `res` and
`last`:

| Occurrence | In `f` (entry) | In `f#` |
|---|---|---|
| self call with `partial L [caps, c]` | `let cell = C [caps, NULL@k]; call f# [args', c, cell, cell]` | `let cell = C [caps, NULL@k]; fill last.k := cell; call f# [args', c, res, cell]` |
| self call with `c` unchanged | unchanged | `call f# [args', c, res, last]` |
| `apply c [v]` | unchanged | `fill last.k := v; apply c [res]` |

The entry never has a chain yet, so its `apply c [v]` stays as is: a
call that never extends costs nothing extra. In `f#`, `c` is passed
unchanged on every path, so it is the invariant `k`.

The dead `L` definitions drop out through DeadCode once no
`partial L` is left.

## Ownership

Everything reuses `trmc.md`'s argument:
- Cells are fresh and reachable only from the chain until
  `apply c [res]` hands `res` to `k`.
- `last` is an ordinary owned reference to the newest cell.
- `RFill` consumes the value and borrows the cell.

RC places every dup and drop for `res`, `last`, the cells and `c`.

`c` itself changes role. Before the rewrite it was consumed each step
by the `partial L` capturing it. In `f#` it is passed along unchanged,
and it is consumed once, by the final `apply`. So the chain of
closures, each holding the previous one, disappears. What remains is
one reference to `k`, which is `id` for `sortBy`.

## Pipeline position

The pass runs right after TRMC, still before RC. It needs:
- `L`'s body visible as a separate definition (it is: Lambda lifting
  made it one);
- self tail calls not yet turned into loops (Loop conversion runs after
  RC).

## Folding `apply id [res]`

For `sortBy`, `k` is the constant closure `id`. After LateInline
splices `f#` into `sortBy`, `c` is a loop parameter that every
`RLoopContinue` passes back unchanged. The `9c6f49e` fix makes
`resolveConstClosureApps` forget every loop parameter, so
`apply c [res]` would stay a dynamic application of `id`. That is
correct but wasteful.

The pass should therefore make `resolveConstClosureApps` keep a loop
parameter that every `RLoopContinue` passes back in its own position:
such a parameter really is its constant. Checking this is one walk of
the loop body.

## Evaluation order

The rewrite evaluates `L`'s cell when the closure used to be built,
not when it would have been applied. `L`'s other fields are captures
or constants (condition 2), so the cell does no work that could fail
or have an effect. The order is unobservable.

## Cost and risk

- **Code size:** each rewritten function exists twice, as with TRMC.
- **Per step:** one cell, one store and a refcount pair on `last`,
  instead of one closure. `sort` also stops paying the n/2-deep chain
  of applications.
- **Condition 3 is the delicate part.** A `c` applied twice on one path,
  or applied and then passed on, must be rejected, because the chain
  can only be closed once.

## Later: arbitrary `c (e x)` (shape 2)

When `L x = c (e caps x)` with `e` not a single constructor
(`foldrImpl`'s `go . f x`), there is no hole to fill. The chain of
closures is already a linked list of frames, though. Each `L` closure
holds its captures and the previous `c`.

Applying it can therefore unwind iteratively: while `c` is a closure of
`L`, read its captures and inner closure, set `v := e caps v`, and
move to the inner one. Then apply what remains.

That needs an IR node to test a closure's function and read its
captures: a `case` over a closure, with the same reuse and ownership
questions as a constructor `case`. It touches every pass, so it is not
part of this design.

## Plan

1. Implement the pass for shape 1. That needs:
   - the `resolveConstClosureApps` refinement above;
   - a `noctx` directive.
2. Add a test covering:
   - `splitRec` itself and `sort` at 1M elements (plus a smaller size
     under valgrind);
   - a user difference list with a non-`id` start;
   - `c` applied once in each of two branches, which is accepted;
   - `c` applied twice on one path, which condition 3 must reject.
3. Measure:
   - `sort` 1M on rc2 against Chez (1.23s);
   - the `scratchpad` `trmc` tool's closure-accumulator count on
     idris2-lsp;
   - build time with `--timing 3`.
