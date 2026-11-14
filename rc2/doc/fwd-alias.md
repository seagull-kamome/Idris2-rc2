# Forwarder aliases (`Compiler.RC2.FwdAlias`)

Disable with `--directive nofwdalias`.

## The problem

A function whose body only calls another with its own parameters, in order,

```
f a b c = g a b c
```

has no use of its own. Arity raising and specialisation leave many: a clone of
a function that `ArityRaise` has split keeps its name as a one-line call of the
raised version, or the raised version is the one that forwards to another. The
calls to `f` were inlined or redirected, but one
reference of another kind kept `f` alive: the target of a closure (`partial f
missing [..]`, a `delay`, a constant closure). `Compiler.RC2.DeadCode` keeps
what is named, and a closure names its function, so the alias stayed in the C,
a call that returns a call.

In the IR of `rc2-norepl`: 871 such functions (boxed, same order), against 61
that pass their parameters in another order and 70 without parameters.

## The pass

`applyFwdAlias`, after the reuse re-check and before dead code elimination:

- `forwarders`: each boxed, non-worker function `f` with parameters whose body is
  one `RAppName` of a boxed, non-worker function `g` with as many parameters,
  called with exactly `f`'s parameters in order, not lazy. `g` is a function of
  the same program, so in incremental mode a call into another module is left.
- `resolve` follows `f -> g -> h` to the end; a cycle stays where it is.
- Every reference to a forwarder is renamed to its target with `FunDedup`'s
  `renameNamesD`: calls, `partial`, `delay` and constant closures.
  A closure constant inside a constant constructor is not reached (its erased
  proof cannot be rebuilt), so a forwarder named there stays.
- The forwarder is not removed here; dead code elimination does it once nothing
  names it. A root stays.

The renaming is right because `f` and `g` take the same parameters in the same
order: a call, or a closure that has captured a prefix of them and misses the
rest, means the same with either name.

## Parameters in another order

`f a b c = g b a c`: a boxed, non-worker `f` whose body is one `RAppName` of a
boxed function `g` of the same arity, called with every parameter of `f` once, in
another order (`permuters`). `permRewrite` runs before the renaming above:

- a call `f xs` becomes a call of `g` with the arguments in `g`'s order;
- a closure `partial f m caps` becomes `partial g m caps'` when the captured
  parameters are the first ones of `g` too (permuted among themselves only) and the
  `m` missing ones stay last, in order: what a later `apply` supplies then lands
  where `f` would have put it. Any other closure keeps `f`.

`delay` and constant closures are not changed (a constant closure captures
nothing, so a permutation always moves a missing parameter).

## Constants added

A wrapper that `MutualLoop` leaves for each member of a merged group has the shape

```
ping a b = {rc2_mutualLoop:0} #0 a b          -- the selector, then the parameters of the member
eval a b c = {rc2_mutualLoop:155} #1 a b c [__] [__]   -- and the padding of the parameters it lacks
```

It passes every parameter once, with constants besides, so it is not an in-order forwarder or a
permutation. `constForwarders` takes a boxed, non-worker `f` whose body is one `RAppName` of a boxed
`g` where every parameter of `f` is passed once and the other arguments are constants (at least one);
`repForwarders` takes the same for a function of any kind whose body is one `RAppNameRep` with no
`postDrop`, the result in the representation of its own, and every parameter passed in its own
representation (the wrapper of a worker, and the worker of a wrapper). `constRewrite` makes each call
of such a function a call of its target, the arguments laid out as the wrapper laid them, constants
included, and runs a few rounds so that a forwarder of a forwarder is followed. A closure keeps the
function: what a later `apply` supplies would not land where the target takes it. The wrapper is
removed by dead code elimination once nothing else names it.

The pass runs before `LeafTail`, so a wrapper still has its tail call as an `RAppName`, and a call of
it in a tail position stays a tail call of the target (closure or direct, as `LeafTail` decides).

`Test175FwdAliasConst`: the calls of the wrappers of a merged `ping`/`pong` are calls of the merged
function, with the same output as `--directive nofwdalias`.

## Not done

- A closure that misses a parameter in the middle: `f` stays.
- A closure over constants (`RCConstPartial`) of a forwarder with another order: it keeps `f`
  (only the function and what it misses are renamed, so an in-order forwarder is reached).
- A forwarder to a permuter is followed one step only; a call that is already a
  `RAppNameRep` is rewritten only for a forwarder with constants (above).
- A forwarder that drops a parameter or repeats one. (One that passes a constant: see above.)
- A forwarder to a `worker`: a closure must take boxed arguments, so the stub that
  unboxes them is needed.
- References inside a constant constructor (see above).

## Test

`Test158FwdAlias`: a function that forwards to another, held in a list with it as a
closure. The IR has fewer forwarders than with `--directive nofwdalias`, and the
output is the same.

`Test160FwdAliasPermuted`: the two closures `mkSwapped` makes, whose lambda calls `joined`
with its captured parameters swapped, become `partial Main.joined`; the one `mkRotated` makes,
which misses a parameter in the middle, keeps its own closure.

## Measured

On `TestAsyncHTTPServer` the definitions go from 902 to 889, the forwarders
from 16 to 3 (the three are named inside constant constructors).

On `rc2-norepl` 137 of the 214 closures that named a forwarder with another order now
name its target (77 are left: 64 forwarders that are not a permutation, 13 that miss a
parameter in the middle), and the definitions go from 13175 to 13136.

On `rc2-norepl` (a build of `libs/prelude` under callgrind, 2026-11-14), the extension for constants removes
about 6.4 million calls of wrappers (the worker of `scan` 4.4 M, `eval` 0.8 M, the worker of `getFirstMatch`
0.7 M, ...), and the instructions go from 29.222 G to 29.217 G (-0.02%), the executable from 15,574,448 to
15,553,016 bytes (-0.14%). About one instruction per call: the C compiler already turns the wrapper's
`return merged(sel, ...)` into a jump, so the call it saves was nearly free. It is a clean-up, not a speed-up.

