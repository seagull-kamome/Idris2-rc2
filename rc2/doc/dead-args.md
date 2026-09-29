# Dead argument elimination (`Compiler.RC2.DeadArgs`)

## Problem

Idris2's elaborator lifts a `where` function to the top level and gives
it every variable of the enclosing clause as an extra argument, used or
not. `Data.List.sortBy` shows the result already in `--dumpcases`,
before lambda lifting:

```
Data.List.sortBy   ... (split [!{arg:2}, !{arg:1}, !{arg:2}]) ...     -- xs, cmp, xs
Data.List.split    = [{arg:1}, {arg:2}, {arg:3}]:
                       splitRec [!{arg:1}, !{arg:2}, !{arg:3}, !{arg:3}, id]
Data.List.splitRec = [{arg:1}, {arg:2}, {arg:4}, {arg:5}, {arg:6}]:
                       ... splitRec [!{arg:1}, !{arg:2}, ...] ...
```

`splitRec` never reads `{arg:1}` (the outer `xs`) or `{arg:2}`
(`cmp`); it only passes them to itself.

That costs more than a register. RC sees a use in the recursive call,
so the outer `xs` is not dropped at entry. After Loop conversion it
becomes a loop invariant held until the loop exits. Holding the list's
head makes every following cell look shared. The half that `splitRec`
rebuilds therefore cannot reuse cells: each is a fresh allocation, and
the old list is torn down as a whole at the end.

On a 1M-element `sort` that was the largest single cost:
- 4.18s instead of 3.21s;
- 2.36x the allocations (1,415,221 instead of 600,197 at 100k).

Adding one such argument to an otherwise identical copy of the code
reproduced both numbers exactly (`TODO.md`, "`sort` against Chez").

`KNOWN-BUGS.md` records the frontend behaviour itself.

## Rewrite

A *slot* is a function and one of its parameter positions. A slot is
dead when both of these hold:
- every use of its parameter is an argument of a call with as many
  arguments as the callee takes (`NmApp (NmRef g) args`), in a lambda
  too;
- each of those argument positions is itself a dead slot.

That is a greatest fixpoint, which also covers mutual forwarding:
`split` passes `{arg:1}` to `splitRec`'s dead slot 0, `hop` and `skip`
pass one to each other.

Every dead parameter is then removed from its function, and the
matching argument from every call. When a dropped argument does work,
every argument of that call that does is first bound by a `let`, in
order, so each is still evaluated once and in its place; the `let` that
only fed a dropped argument becomes an ordinary dead binding.

## What keeps a signature

A function keeps its parameters when changing them would break some
reference that isn't a plain call:
- **Referenced other than by such a call:** a bare `NmRef`, or a
  `Force` of one. (A partial application is a lambda around a
  saturated call on the case trees, which is fine.)
- **Called with a different number of arguments** than it takes.
- **A root** (entry points, exports).
- **Incremental compilation** (`doc/incremental-compile.md`): another
  module's calls are out of sight, so the whole pass is off.

## Pipeline position

The pass runs on the named case trees, right after inlining and before
lambda lifting (`Compiler.RC2.DeadArgs`, 2026-09-29; before that it ran
on RCExp right after "RC normalize"). Every later pass sees the leaner
signatures, lambda lifting included: a lambda that only forwarded a
dead value no longer captures it.

That is also why the case trees find more. On RCExp such a lambda was
a lifted definition holding the value, referenced by a partial
application, so it kept its signature and the value counted as used.
On idris2-lsp the pass removes 4,718 of 19,219 parameters of top-level
functions, against 1,875 of 66,385 (lifted lambdas included) on
RCExp; `rcexpr-lint` finds no anomalies, with 2,964 fewer `dup`
increments, 16,378 fewer `drop` decrements and 28 fewer closures.
The pass takes 0.87s instead of 0.65s.

## Results (2026-09-26)

- `Data.List.sort`, 1M `Int`s: 4.18s to 3.21s, allocations back to
  600,197 at 100k.
- `Test99DeadArgs` covers:
  - a `where` helper;
  - mutual forwarding;
  - a function with a dead argument that is also partially applied, so
    it keeps its signature;
  - `sort`.

  It matches Chez's output and is clean under valgrind.
- idris2-lsp: 1,875 of 66,385 parameters removed. `rcexpr-lint` finds
  no anomalies. The pass takes 0.82s.
  - A first version took 2.07s. `concatMap` over every definition was a
    left fold of `++`, quadratic over the program; `foldr (++) []`
    fixed that.
  - The dead-slot fixpoint is a worklist over reversed forwarding
    edges, so each edge is visited once.
