# Upstream's tail-recursive list functions, replaced (`Compiler.RC2.ListDivert`)

Off by default; `--directive listdivert` (or `%cg rc2 listdivert` in the program) turns it on.
Whole-program compiles only.

## The problem

`Prelude.Types` rewrites the list functions that recurse under a `::` into tail-recursive
ones, with `%transform` rules, for the backends whose stack a long list would overflow:

| source | at run time | passes | cells |
|---|---|---|---|
| `xs ++ ys` | `tailRecAppend`: `reverseOnto ys (reverse xs)` | 2 over `xs` | 2n, n of them an intermediate list |
| `map f xs` | `mapTR`: `mapAppend [<] f xs`, then `<>>` | 2 | 2n |
| `filter p xs` | `filterTR`: `filterAppend` then `<>>` | 2 | 2k |
| `mapMaybe f xs` | `mapMaybeTR` | 2 | 2k |

rc2 has `Compiler.RC2.Trmc` (`trmc.md`): the naive `x :: f xs` is one loop that fills the
hole of each cell, n cells, constant stack. Under rc2 the upstream rules only double the
allocation and the `teardown` of every `++`, `map`, `filter` and `mapMaybe`. In the case
trees of `rc2-norepl` the `++` shape appears 815 times, `mapAppend` 2,086, `mapMaybeAppend`
185, `filterAppend` 132.

## The pass

`applyListDivert`, on the named case trees right after `applyLazyCaf` and before
`InlineCExp` (`Compiler.RC2.RC2`): every call of an upstream helper becomes a call of a
definition of rc2's own, added to the program when used,

- `tailRecAppend xs ys`, and the shapes the inliner leaves of it (`reverseOnto ys
  (reverseOnto [] xs)`, `reverseOnto ys (reverse xs)`), to `rc2_append xs ys`;
- `mapAppend [<] f xs` (`mapTR` is `%inline`, so this is what the frontend leaves) to
  `rc2_map f xs`, and `filterAppend`/`mapMaybeAppend` with `[<]` to `rc2_filter`/`rc2_mapMaybe`.

The four definitions are the naive ones, in the shape TRMC takes (the recursive call the last
field of the `::`; `filter` and `mapMaybe` mix a plain tail call in, which TRMC's phase 1
covers). A `Bool` alternative is a `B8` constant, as upstream's `Compiler.Opts.Constructor`
makes enum constructors. `SnocList`'s own rules are left alone: a snoc list is built reversed
by nature. `length` is left alone too (`lengthPlus` allocates nothing).

Only a whole-program compile runs the pass: the added definitions are one per program,
and a per-module compile would add a copy to each module.

## Measured

Off by default, because the gain depends on the program: the compiler's own `prelude`
build, all short lists, is unchanged in instructions (27.97 G off, 28.00 G on: +0.09%) and in time, and
its executable grows 5.5% (the per-call-site clones of `map` are TRMC loops, 225 of them
at 49 lines against 197 `mapAppend` clones at 23); a list-heavy program gains about a
quarter of its time:

| | before | after |
|---|---|---|
| `BenchListAppend` (two 500k lists appended, 40 times) | 6.80 s | 5.18 s (-24%) |
| `BenchListChurn` (map, filter, sum of 300k, 50 times) | 2.35 s | 1.82 s (-23%) |

`Test178ListDivert`: `++`, `map`, `filter` and `mapMaybe` leave no upstream helper in the
IR and TRMC fills the holes under `listdivert`; the output is the same as without it and under RefC.

`verify.sh --directive listdivert` runs the suite with the pass on. Every output matches;
two checks that count IR nodes against a variant their `check.sh` builds without the
global directive (`Test112Numeric`'s comparison-merge counts, `Test13NativeArgChain`'s
`noboolfield` counts) report a difference there, as any global directive that changes the
list code would make them.

## Fusion (`--directive listfuse`)

With `listfuse` (which also turns `listdivert` on) the same pass makes one loop of a chain of
the diverted calls. A call `rc2_map f (rc2_filter p xs)` made a list that `map` read next; now
one function, `rc2_fuse_fm`, takes `f`, `p` and `xs` and does both per element, and TRMC turns
it into one loop that allocates only the result.

- **What is fused.** A chain of `map`, `filter` and `mapMaybe` calls, up to six, each the
  last argument (the list) of the next; and `xs ++ ys` whose `xs` is such a chain, where the
  loop ends in `ys` instead of `[]` (`rc2_fuse_mf_t`). A chain of one with no `++` is left as
  it is. The name spells the stages, first applied first (`m` map, `f` filter, `j` mapMaybe),
  and `_t` an end list. The definition is made once per shape and per program; a stage
  function stays a parameter, so `SpecClosure` still specialises it for a constant closure.
- **Where.** Bottom-up in the call rewriting that makes the diverted calls, so an inner chain is
  fused before the one that reads it, and an inner chain that has an end list is not extended
  (`map f (xs ++ ys)` is not `map f xs ++ map f ys`).
- **Consumers.** `foldl`, `foldr` and `length` (`lengthPlus`) of a chain are one loop too
  (`rc2_foldl_mf`, `rc2_foldr_m`, `rc2_length_f`): the stages, the consumer's own parameters
  (`g` and the accumulator, `z`, or the count) and the list. `foldl` and `length` are tail
  calls, so the loop never builds the list at all; `foldr` keeps the call it had, which makes
  the result. `sum` and the like are `foldl` once `Foldable` is specialised.
- **Twice.** Inlining makes the shapes `length (filter p xs)` and `sum (map f xs)` have: a
  function's list argument becomes a `let` the body reads once (`let l = chain in
  lengthPlus [0, l]`). So the pass runs a second time after `InlineCExp`, and treats a `let`
  that only its body's last argument reads as the call's argument; the second run adds no
  definition the first made.
- **Intermediate lists are never shared.** A chain is only a call nested directly in the
  argument of the next, so the intermediate list has no other reader.

### Design decision: the order of effects is not kept

Fusing changes the order in which the stage functions run: `map f (map g xs)` ran `g` on
every element and then `f` on every element, and the loop runs `g` and `f` on one element
and then on the next. For pure functions that is unobservable. A stage function that calls
`unsafePerformIO`, or `crash`, is taken to be pure by whoever wrote it, and its effects may
come in a different order or, for a filter that drops an element a later stage would have
crashed on, not at all. The pass does not look for them: such a function is written knowing
it may be treated as pure, as it is by every other pass, and the whole stage is opt-in. IO
loops (`traverse_`, `forM_`, `mapM_`) are other functions and are not touched; a list of
`IO` actions is only built by `map`, and running them is later.

### Measured

Survey of the compiler's own NamedCExp (static, 3,350 diverted calls): about 70 chains of
two, 126 `++` whose first argument is `map`, `filter` or `mapMaybe`, and 63 folds
(`foldMap`, `foldr`, `foldl`) that read one directly. `foldMap` is not fused.

| | `listdivert` | `listfuse` |
|---|---|---|
| `BenchListFuse` (four chains of 500k, two of them consumed by `sum` and `length`, 40 times) | 6.54 s | 5.44 s (-17%) |

The compiler's own `prelude` build (short lists; self-built with the directive, instructions
and executable size): off 27.964 G, 15.68 MB; `listdivert` 27.984 G, 16.56 MB; `listfuse`
27.990 G, 16.56 MB with the consumers (27.979 G, 16.55 MB before them). Fusion neither helps
nor costs there.

`Test180ListFuse`: nine fused shapes, with and without an end list, and a `foldl`, `foldr` and
`length` over a chain, over a list, `[]` and a list a filter empties; the output is the same as
without the directive.
