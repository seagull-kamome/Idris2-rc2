# Calls that need no trampoline

`Compiler.RC2.Pending`, used by `Compiler.RC2.Emit`. No directive turns it
off; `--directive dumppending` writes its result to a `.pending` file.

## The problem

A tail call is made as a closure that the nearest non-tail caller runs
(`leaf-tail-calls.md`), so every non-tail call of a boxed function is wrapped
in `idris2rc2_trampoline`: the callee might hand back such a closure. Most
callees never do, and the wrapper was paid on every call (about 230 million
calls in a prelude build, 9.5% of all instructions before its guard was
inlined).

## The analysis

A boxed function can return a *pending* closure only through a tail that
is one of:

- a tail `RAppName` (`Emit` builds the closure) or a lazy one,
- a tail `RApp` (`idris2rc2_tailcallApplyClosure` returns the grown closure,
  saturated or not),
- a `RMemoize`, or any form not listed as finished below,
- a direct call (`RAppNameRep`, boxed result: what `LeafTail` and DualABI
  make) to a function that may itself return one.

The finished forms are a local, a constructor (also by value or on the
stack), a literal, an erased value, `RCrash`, a partial application
(`RUnderApp`), an inline foreign call, `RDelay`/`RForce`, and a primitive or
external primitive that is not lazy. A local is finished because every
value that reached it came through a trampoline or a data structure, and
a stored closure is partial.

`pendingFuns` is the least set with every function that has a `Pending` tail
and every function that passes on the result of a call to a member or to a
function not defined in the compile. The rest of the boxed functions, and
every constructor and foreign wrapper defined in the compile, are
`trampolineFree`: `Emit` leaves the wrapper off a non-tail call to one. A
call that `Emit` makes through a closure (more arguments than
`MaxExtractFunArgs`) keeps it.

An incremental (per-module) compile sees only its own definitions, so a call
to another module is always wrapped. Carrying the bit across modules would
need it in the module's output.

## Results

compiler self-build, prelude and base (gcc), with the guard of
`idris2rc2_trampoline` already inline: instructions 29.63 G -> 29.21 G
(-1.4%), prelude 5.33 s -> 5.26 s, base 67.8 s -> 67.0 s, executable
15.92 MB -> 15.53 MB. 36804 non-tail call sites in the compiler, 31947 of them
(87%) call a function that is not pending; 1418 of 9432 boxed functions are.
