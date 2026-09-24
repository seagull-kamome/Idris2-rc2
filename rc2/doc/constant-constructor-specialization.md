# Constant-constructor argument specialization

Specializes a callee on an argument that is a compile-time-constant
*constructor* -- in practice an interface dictionary -- turning the
boxed method dispatch inside it into a direct call.

Lives in the lower half of `rc2/src/Compiler/RC2/SpecClosure.idr`
(`applySpecConstCon`), sharing that module's structural helpers and
pipeline position with its closure-argument sibling. Disable with
`--directive nospecconstcon`. See
`speculative-closure-specialization.md` for the closure half, whose
three-step shape and profitability discipline this deliberately
mirrors.

## The gap it fills

`SpecClosure` specializes a callee on a *closure* argument: a
parameter that gets **applied**. It cannot see the interface-dictionary
case, because there the argument is a record that gets
**destructured**:

```
def Prelude.Types.elemBy  (fun args= ["v10077", "v10078", "v10079"] ret= Boxed)
  case v10077 of                                       -- (1) destructure
    Prelude.Interfaces.MkFoldable [record] args= [_, _, _, _, _, v10085] ->
      let v10087 = apply v10078 [v10079]
      apply v10085 [..., v10087]                       -- (2) boxed dispatch
```

`v10077` is used *only* as a `case` scrutinee, and its callers pass a
dictionary `Compiler.RC2.ConstFold` has already folded to a single
`RCConstCon` whose fields are `RCConstClosure`s. Everything needed to
resolve the dispatch is therefore known at compile time -- it just
never reaches the callee's own body.

## Why nothing new is needed downstream

Getting the constant to the body **is** the whole rewrite. The existing
chain finishes the job on its own:

1. `ConstFold`'s `RConCase` scrutinee resolution folds the `case` away
   against the known `RCConstCon` and binds each alt field to the
   corresponding constant (`insertConArgs`).
2. Each method field is then an `RCConstClosure`, so `ConstFold`'s
   `RApp` case rewrites `apply` into a direct `RAppName` call (or an
   `RUnderApp` when under-applied). See `const-closure-fold.md`.
3. `Inline`/`LateInline`/`DualABI` can then see through the now-named
   call, which they never could through an `RApp`.

That is why there is no `rewriteApply` analogue here, unlike the
closure half: substitution plus the existing fold is the entire
transformation.

## The three steps

1. **Candidate detection.** For each call site `call g [..., c, ...]`
   where `c` is an `RCConstCon`, and `g`'s parameter at that position
   is scrutinised at least once and used *nowhere* except as an
   `RConCase` scrutinee or as a passthrough of itself at the same
   argument position of `g`'s own recursive call, record the triple
   `(g, argPos, c)`. `paramIsScrutineeOnly` is the gate -- modelled on
   the closure half's `paramLooksSpecializable`, with `apply` swapped
   for "scrutinee of an `RConCase`" and sharing its
   `selfPassthroughOccurrences` verbatim. Because `ConstFold` has
   already run to a fixpoint over the whole program by this point, a
   constant argument is spelled out right at the call site and never
   still behind an `RLet`, so unlike the closure half there is no
   `Bound` environment to thread.

   **The self-passthrough allowance needs no machinery of its own**,
   which is why it is worth stating explicitly. A recursive `go`
   carrying its dictionary along on every step is the shape a real
   interface dictionary almost always has, and refusing it was
   rejecting most of the opportunity. Allowing it just works: the
   seeded fold substitutes the constant into the recursive call too,
   leaving it calling the *generic* callee with the constant spelled
   out, and step 3's whole-program redirect sweep runs over the clones
   as well as the originals -- so that call matches this very key's own
   redirect entry and becomes a call to the clone itself, argument
   dropped. The recursion specializes all the way down for free.

2. **Speculative clone + re-fold**, memoized per distinct triple.
   Clone `g` with the parameter dropped from the signature and its id
   seeded into the fold's own `Env` -- `ConstFold.foldConstDefWith`,
   added for exactly this.

3. **Profitability gate.** Keep the clone only if it holds strictly
   fewer `RApp` nodes than the original. After substitution the
   specialized parameter has disappeared entirely, so this is the
   honest structural question: did this remove the dispatch it was
   built to remove? Otherwise discard, and every call site keeps
   calling the generic `g`.

Pipeline position: straight after `applySpecClosure`, so it consumes
that pass's own clones (a clone is an ordinary `MkRCFun` by then), and
strictly before `insertMemoize`/Phase 2, so its own clones are likewise
ordinary by the time those see them.

## The `where`-clause trap that got this reverted once

This pass was designed, implemented, measured and **rejected** on
2026-09-24, recorded in `TODO.md` as costing 103 seconds of a
whole-`idris2-lsp` build for 193 fewer dispatches. It was re-measured
the same day and the rejection was wrong. The cost was not the pass.

`goKeys` looked up each key's callee in a `defOf : SortedMap Name
RCDef`, written as a `where` clause:

```idris
  where
    defOf : SortedMap Name RCDef
    defOf = SortedMap.fromList defs        -- looks like a constant
```

A `where` definition is lambda-lifted into a function of whatever
enclosing pattern variables it mentions, so this is really `defOf
defs` -- **re-evaluated at every single use**. `goKeys` uses it once
per key, so ~1,600 keys meant ~1,600 rebuilds of a 38k-entry map.
Binding it once in the function body and threading it into `goKeys` as
a parameter (which `applySpecClosure`'s own `goKeys` already did):

| | before | after |
|---|---|---|
| `goKeys` | 102.9s | **0.010s** |
| whole `idris2-lsp` build | 131s | 27.7s |

The attribution was done by ablation, gating each phase behind a
throwaway directive and subtracting consecutive whole-build times.
Worth recording because two plausible suspects were measured **innocent**
before the real one was found, and the first investigation had named
one of them:

| phase | cost |
|---|---|
| build the `(Name, Nat, RCLocal)` key set -- deep constant trees as `SortedMap` keys | 0.044s |
| rebuild the CAF table | 0.001s |
| `goKeys` | **102.9s** |
| rewrite every call site, deep `RCLocal` `==` per entry | 0.085s |

The decisive step was counting nodes: all 1,598 keys' bodies came to
**23,911 nodes total**, and walking them took 104 seconds. At 4.3ms per
node the walk obviously was not the work, which left only the one
`lookup` beside it.

**If you add a `where`-bound collection to a pass, check how many times
it is referenced.** Once, handed onward as a parameter, is safe; once
per element of anything is not.

## Measured

Whole `idris2-lsp` build, against the same build with
`--directive nospecconstcon`:

| | off | on |
|---|---|---|
| `apply` nodes | 11,384 | **11,182** (-202) |
| definitions after `DeadCode` | 26,387 | **25,978** (-409) |
| successful constructor reuses (`reuse=`) | 21,829 | **22,195** (+366) |
| native `RLet`s | 3,349 | 3,422 (+73) |
| IR lines | 732,238 | 735,646 (+0.5%) |
| `dup` / `drop` | 93,645 / 77,223 | 94,165 / 77,813 (+0.6%) |
| compile time (median of 3) | 27.49s | 28.59s (+4.0%) |

The definition count *falls* despite the clones: `DeadCode` prunes more
newly-callerless originals than the profitability gate keeps clones.

Runtime, median of 5, each benchmark A/B'd against itself with
`--directive nospecconstcon`:

| | off | on | |
|---|---|---|---|
| `rc2/tests/BenchSpecConstCon.idr` | 0.48s | **0.37s** | ~23% faster |
| `rc2/tests/BenchSpecConstConRec.idr` | 0.49s | **0.40s** | ~18% faster |

`idris2rc2_applyClosure` call sites in each one's generated C go 4 to
0. The two cover the gate's two halves: the first reaches a
non-recursive callee, the second threads the dictionary through its
own recursion.

**The whole-program IR counts understate this.** Nine fewer `apply`
nodes is what the self-passthrough allowance is worth *statically* on
`idris2-lsp`, but a dictionary-threading recursion is a loop: the
dispatch it removes is paid once per iteration, not once per node.
`BenchSpecConstConRec` is the honest measure of that shape, and the
shape is the common one in ordinary Idris code.

## Why the whole-program yield is only ~1.8%

Both reasons are inherent to the gate, not bugs. On `idris2-lsp`, of
1,598 distinct keys:

- **903 (57%) fail the scrutinee-only gate** -- the dictionary is
  passed on to some *other* callee, not just scrutinised and carried
  through its own recursion. Resolving those needs interprocedural
  specialization (propagating the constant down a call chain), which
  is a different and much larger feature.
- **117 more fail the profitability gate** -- 695 keys pass the first
  gate and 578 clones are kept. The discarded ones folded the `case`
  away but left the dispatch somewhere the fold could not reach.

Of the 578 clones the pass keeps, 73 survive to the final IR. That is
not 505 wasted: a clone with exactly one caller is precisely what
`LateInline` splices away, which is better than the call it replaced.

The `--directive timing` output prints this breakdown (`N distinct
keys`, then `N keys past the scrutinee-only gate, M clones kept`), so
it can be re-derived on any program without rebuilding the compiler.

## Open

- **Multiple specialized parameters** (a function taking two
  dictionaries) -- the same open question the closure half has, out of
  scope the same way: one parameter position at a time.
- **Not iterated to a fixpoint**, same as the closure half: a kept
  clone can expose a further opportunity.
- **Interprocedural propagation** -- the 903 keys above, where the
  dictionary is handed to a different callee. This is where all the
  remaining yield is, and it is not a relaxation of this gate but a
  separate analysis.

## Files

- `rc2/src/Compiler/RC2/SpecClosure.idr` -- `applySpecConstCon` and its
  own section, below the closure half.
- `rc2/src/Compiler/RC2/ConstFold.idr` -- `foldConstDefWith`, the
  seeded fold entry point this pass needs.
- `rc2/src/Compiler/RC2/RC2.idr` -- pipeline position, `nospecconstcon`
  in `disableableStageNames`.
- `rc2/tests/Test87SpecConstCon/` -- correctness, plus `verify.sh`'s own
  assertion that clones are kept and no boxed dispatch survives.
- `rc2/tests/BenchSpecConstCon.idr`,
  `rc2/tests/BenchSpecConstConRec.idr` -- the two runtime A/Bs above,
  one per half of the gate.
