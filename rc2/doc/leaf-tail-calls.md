# Direct tail calls to leaf functions

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

## The rule

A *leaf* is a function whose every tail is a value (a variable, a
constructor, a partial application, an operator, a primitive, a crash) or a
tail call of another leaf. The set is the least fixpoint, so a cycle of tail
calls is never in it. A leaf returns after a bounded amount of its own work
and never hands back work to be trampolined, so calling it from a tail
position cannot make the C stack grow with the length of a chain. Calls that
are not in tail position inside a leaf are as deep as they always were.

The pass rewrites a tail `RAppName` of a leaf into

```
let x : Boxed = call leaf [args]
x
```

which `Emit` renders as a plain call (`idris2rc2_trampoline(leaf(args))`,
a no-op on a value). Only boxed functions with arguments are leaves; loops,
worker calls (`RAppNameRep`) and `apply` tails are not looked into.

## Measured

`TestAsyncHTTPServer`: closures that are built saturated (deferred calls)
282 -> 176; those of `>>=` of `Task` 45 -> 11. `GET /hello`, one connection,
one thread, instructions in user space per request (`perf stat`): 402 000
-> 390 000, about 3 per cent. `bench.sh` shows no difference beyond noise.

## Not done

- Tail calls to a function with a native worker still go through its boxed
  wrapper (`TODO.md`).
- A leaf may call a non-leaf in non-tail position. For `N x = L x` with a
  leaf `L` that calls `N` in non-tail position, the closure of `L` used to
  be run by the trampoline at the depth of `N`'s caller; now `N`, `L`, `N`
  each add a C frame. The depth stays that of the non-tail recursion, with
  one more frame per round through a forwarder. The rule could be tightened
  to leaves with no calls at all in non-tail positions if that ever shows.
