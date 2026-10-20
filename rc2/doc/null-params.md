# Parameters that hold NULL: the world and erased values

The world token and an erased value are always C `NULL`
(`doc/world-erased-marks.md`). `Compiler.RC2.NullParams` finds the
parameters that can only ever hold one of them, and `DualABI` gives each
such parameter a native type, so the worker takes no reference count on it.

## The types

`NativeTy` has `TPrim WorldType` (the world) and `TErased`. Both carry no
value, so `Types.tyAlwaysUnboxed` is true and `Types.nullTy` picks them out.
Their C types are pointers to opaque structs, `IDRIS2RC2_World *` and
`IDRIS2RC2_Erased *` (`support/rc2/idris2rc2_datatypes.h`), so the C compiler
keeps them apart from each other and from an `IDRIS2RC2_Value *`.

- Boxing one (`tyMk`) is a `NULL` `IDRIS2RC2_Value *`; unboxing (`tyUnbox`)
  is a typed `NULL` whatever the Boxed value was.
- `nullOfTy` is what a constant `[__]`, `[erased]` or `[world]` reads as where
  a native type is wanted.
- A dump prints them as `Native %World` and `Native Erased`.
  `rcexpr-lint` counts both as always-unboxed (`Leak.unboxedTypeNames`).

## Where the types come from

`NullParams.nullParamTable roots defs` returns, per function, the parameter
ids that are NULL-typed. Two sources:

1. **By type, backward.** A `%foreign` declaration's `CFWorld` slot is the
   world. A parameter passed at such a slot of a `call` (`RAppName`) or a
   partial application (`RUnderApp`) is the world too, and so on through
   named callees until nothing new is found. A variable has one type, so this
   holds for a function that escapes as well (a closure, an export).
2. **By value, forward.** A function is *closed* when every reference to it
   is a call or an `RUnderApp` with a known argument list (not a constant
   closure, an `RDelay`, a dual-ABI worker call, nor a root). For such a
   function, parameter `i` is NULL-typed when every call passes `[world]` or
   `[erased]` at `i`, or a parameter of the caller that is itself NULL-typed;
   an `RUnderApp` must cover `i` (the arguments after its prefix come from
   callers this pass cannot see). The analysis starts from "every parameter is"
   and removes what a site contradicts, so a parameter that is only handed
   round a recursion stays unreported. All world: `TPrim WorldType`;
   otherwise `TErased` (both are NULL).

Functions merged by `MutualLoop` are left out. `--directive nonullparams`
turns the analysis off.

## What `DualABI` does with it

`applyDualABI` adds the NULL-typed parameters to a function's `eligible`
list, so it gets a worker (native parameters) and a thin wrapper that keeps the
Boxed signature, like any other native parameter.

- The worker's `dup`/`drop`/`free`/`postDrop` on the parameter are removed
  (`stripOwnership`); `RExtPrim`'s `postDrop` is stripped too. Every read of
  the parameter (and of its aliases) becomes the constant `[world]` or
  `[erased]` (`nullReads`), so a later pass sees a constant.
- A `let` that only renames a NULL-typed local is NULL as well, so it becomes
  a native local of the same type and loses its ownership operations
  (`nullAliasTypes`, `nativeAliasLets`).
- An `RLoop` whose parameter has the same id as the function's parameter takes
  the same native type (`retypeNullLoopParams`). `Emit.declareLoopParam`
  declares nothing for it when the C variable of that id already has that
  type (the parameter, or the alias `let`), as the loop start now reads a
  constant rather than the variable itself.
- The wrapper does not drop such an argument: it is NULL.
- Callers are rewritten to call the worker by the ordinary call-site rewrite.

The parameter stays in the signature. Arity, the position of the world and the
order of effects do not change, so `ArityRaise` and `IO` evaluation are
untouched; `worldInPrefix` is still the guard there, as a mark of "is the
world" does not prove "is not the world" (`doc/world-erased-marks.md`).

## Measured

Before the constant rewrite, over the 56 smoke-test IR dumps: 190 parameters marked (169 world, 21
erased); `dup` 2111 -> 2058, `drop` 3795 -> 3782.

On idris2-lsp (`9a2f0ad`, 13.2k definitions), against the build before this
change (master at the merge of #119):

| | before | after |
| --- | --- | --- |
| `dup` | 73320 | 69886 (-4.7%) |
| `drop` | 62606 | 61594 (-1.6%) |
| both | 135926 | 131480 (-3.3%) |
| workers | 1687 | 2031 |
| IR lines | 629736 | 628232 |

667 parameters are marked (639 world, 28 erased). 344 functions gain a worker
only for this; the IR still shrinks, as the `dup`/`drop` lines they save
outnumber the lines the workers add. `rcexpr-lint` finds no anomaly in either
dump. Compile time was not measured.

## Loops that share a slot

`MutualLoop` merges the states of mutually recursive functions into one loop
whose slots mean different things in different states, and `LateInline` can
put such a loop inside any function. A loop slot that holds a NULL-typed
parameter (or an alias of it) is therefore kept `NULL`-typed only when the loop
start and every `continue` feed that slot a NULL-typed local or `[__]`,
`[erased]`, `[world]` (`DualABI.mixedSlots`). Any other slot makes the
parameter stay `Boxed`. Without this check 6 loops on idris2-lsp passed an
object in a slot typed as the world.


## Compile time

On idris2-lsp the whole build goes from 56 s to 58-59 s (two runs each,
`--directive nonullparams` against the default); `DualABI` from 2.6 s to 4.3 s.
The analysis keys its fixpoints by a number given to each name once (comparing
`Name`s was most of the first version's cost). Two traps cost minutes before
they were found:

- `let x : T` with a separate `x = e` makes `x` a *function*: every use
  evaluates `e` again. A value is bound as `let x : T := e`. The first version
  ran the whole forward fixpoint once per function.
- `concatMap` over a list of lists nests `++` to the left and copies the
  accumulated list per element (`foldr (\g, acc => ... ++ acc) []` does not).

## Not done

- `Loop` does not see these types: a loop parameter that is not the function's
  own parameter (or an alias of it), and is initialised from one, stays Boxed.
- A parameter only passed on (never to a `%foreign` world slot, nor by every
  caller as a constant) stays Boxed.
