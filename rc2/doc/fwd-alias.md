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

## Not done

- Parameters in another order (`f a b c = g b a c`). A call can be rewritten with
  its arguments permuted; a closure only when the missing parameters stay the
  last ones of `g`. 61 functions in `rc2-norepl`.
- A forwarder that drops a parameter or passes a constant.
- References inside a constant constructor (see above).

## Test

`Test158FwdAlias`: a function that forwards to another, held in a list with it as a
closure. The IR has fewer forwarders than with `--directive nofwdalias`, and the
output is the same.

## Measured

On `TestAsyncHTTPServer` the definitions go from 902 to 889, the forwarders
from 16 to 3 (the three are named inside constant constructors).
