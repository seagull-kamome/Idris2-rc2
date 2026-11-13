# Direct tail calls out of a cycle-free callee set

`Compiler.RC2.LeafTail`, the pass just before dead-variable erasure.
Disable with `--directive noleaftail`.

## The problem

A tail-position `RAppName` is never a C call. `Emit` builds a closure for
it, the function returns the closure, and the nearest non-tail caller runs
it in `idris2rc2_trampoline`'s loop, so a long chain of tail calls takes
constant C stack (`inlining.md`, "Not even load-bearing"). A forwarder
pays for this on every call:

```
Control.Task.>>=  =  bind          -- returns a closure of bind
```

`Control_Task__gt_gt_eq_Monad_Task` allocates a closure for `bind`, the
trampoline runs it, and `bind` builds a constructor and returns it: two
allocations and two dispatches for one `>>=`.

## When a direct call is safe

The closure is there to keep a chain of tail calls from growing the C
stack. A direct tail call `f -> g` adds the frame of `g` on top of `f`'s
while `g` runs, and `g`'s result is returned by `f` as it is: a value, or a
pending call of `g`'s own, which `f` hands up to the trampoline of its
caller. The stack therefore grows without bound only if the *direct* calls
close a cycle (`f -> g -> ... -> f`, every edge a C call). Edges that stay
closures never nest.

So the pass keeps the closure on exactly the tail calls that stay inside one
strongly connected component of the tail-call graph, and makes every other
known tail call direct. The depth of the direct chains is then bounded by the
number of components, a constant of the program.

## The graph

Nodes are the functions of the program. An edge `f -> g` is a tail position
of `f`'s body that calls `g`:

- an `RAppName` (a boxed call, the edge the pass may make direct);
- an `RAppNameRep` (a worker call, already a C call; it is an edge so a
  cycle through workers is not missed);
- through a loop: the tails of an `RLoop` body are tails of the function
  (`RLoopContinue` is not a call).

A tail `apply` (`RApp`), a force and a `RMemoize` are not edges. A tail
`apply` of one argument returns a pending call; the others run the closure
inside a nested C call, a nesting this pass does not add to. Only callees
defined in the same program (`defs`) are edges; in incremental mode a call
into another module stays a closure.

## The rewrite

A tail `RAppName callee args` becomes

```
RAppNameRep callee [RBoxed, ...] RBoxed [] args
```

which `Emit` renders as `return callee(args)` in tail position (the result
is not trampolined) and as `idris2rc2_trampoline(callee(args))` anywhere
else. It is made when

- `callee` is a boxed entry (`MkRCFun`, not a worker, boxed result) with
  1 to `MaxExtractFunArgs` parameters, as many as the call passes, and
- `callee` and the caller are in different components.

A self call and a call inside a cycle that no loop conversion removed keep
their closure. The rewrite is made in every `MkRCFun` with a boxed result, a
worker as well as a boxed function.

## Relation to the earlier leaf rule

The pass used to make a tail call direct only when the callee was a *leaf*:
every tail a value or a call of another leaf. A leaf is never in a cycle, so
this is a special case of the rule above. What it left out, and the
component rule takes in: callees that end in a loop (`tailChildren` did not
enter `RLoop`, so every function with a converted loop was out), callees
that tail-call a worker, and callees that tail-call a function that is not a
leaf.

## Measured

`libs/prelude` built by the `rc2`-built compiler (callgrind):

| | leaf rule only | component rule |
|---|---|---|
| instructions | 39.14 G | 36.94 G (-5.6%) |
| `idris2rc2_mkClosure` calls | 25.9 M | 14.7 M |
| `idris2rc2_trampoline` runs | 19.6 M | 8.4 M |

Building `rc2-norepl` with the Chez-built `idris2-rc2` takes 10 min 3 s with the
component rule and 10 min 47 s with the leaf rule only (one run each, C
compilation included). Earlier, for
the leaf rule alone, `TestAsyncHTTPServer`: closures built saturated 282 ->
176, those of `>>=` of `Task` 45 -> 11.

## Cost of the pass

The components are computed once per program (`tarjanSCCs`, shared with
`MutualLoop`). They must not be rebuilt per call: a first version kept the
graph in a `let` block next to a local function and recomputed it for every
tail call, which made the pass take 7 s on `TestAsyncHTTPServer` and more
than half an hour on `rc2-norepl`. The helpers are top-level functions that
take the maps as arguments.

## Stack depth

Before, `N x = L x` with `L` calling `N` in a non-tail position left `L`
to the trampoline of `N`'s caller. Now `N` calls `L`, so such a round of
non-tail recursion can have one more C frame. The depth is still that of the
non-tail recursion.

One case was measured: `nrec n = lstep n` with `lstep n = 1 + nrec (n - 1)` and
an 8 MB stack ran 100 000 levels deep with the pass and 60 000 without it
(`--directive noleaftail`). Why the frames got smaller was not investigated.

## Not done

- Tail calls to a function with a native worker still go through its boxed
  wrapper (`TODO.md`).
- Foreign wrappers (`MkRCForeign`) are not callees: they never return a
  pending call, so they could be, but their entry has its own convention.
- A tail `apply` of a known closure is not looked into.

## Test

`Test110Loop/LeafTail` (forwarders, and a mutual cycle that `MutualLoop` turns into a loop),
`Test154SccTail` (a callee that ends in a loop is called directly; a cycle
kept by `--directive nomutualloop --directive noloop` keeps its closures
and runs a million bounces).

## What is left (2026-11-13)

Three ideas were considered to go further, and a count (a throwaway patch: the class of each
tail `RAppName` that stays a closure, and where each pending call at run time comes from) showed
that none of them has anything to take.

- **Direct calls inside a component, cutting only the back edges.** The rule above keeps the closure
  on every edge inside a component. It would suffice to keep it on the back edges of a depth-first
  search of each component (every cycle holds one), with the chains of direct calls bounded by the
  longest path without them. In the final IR of `rc2-norepl` no component with a tail edge inside is left:
  `MutualLoop` and `Loop` have turned every cycle into a loop. The 106 tail `RAppName` sites that stay
  closures all call a function that cannot be called directly (a worker, an arity that does not match).
- **A per-thread register instead of a heap closure for a pending call**, returned as a static marker.
  Only a closure that `Emit` builds for a tail `RAppName` could use it, and there are few (below).
- **Direct application up to a depth** (a depth counter; past the limit, return the pending call as now).
  It applies to the tail `apply` of an unknown closure, not to the calls above; it saves the return and
  the loop test of one trampoline round, 10 to 20 instructions of the 100 or so of a dispatch, since the
  closure's shell is still released and the arity still dispatched. A long loop (`loop = act >> loop`)
  would run at the limit, as it does now, so only short chains gain. About 0.3-0.7% of the instructions
  at best. Not done.

Where the pending calls come from, `libs/prelude` built by the `rc2`-built compiler (counters in the
runtime, 2026-11-13):

| origin | count |
|---|---|
| a closure built for a tail `RAppName` | 32,394 |
| a tail `apply` of a unique closure, grown in place | 8,779,370 |
| a tail `apply` of a closure with other references, copied | 3,063,056 |
| trampoline dispatches | 8,149,962 |

99.6% of the pending calls are tail `apply`s of a closure that is not known where it is applied (the
continuation of a monadic bind, for one). For those the known-callee rules here do nothing; removing them
means making the closure known: `speculative-closure-specialization.md`.
