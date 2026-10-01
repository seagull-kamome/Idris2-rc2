# Memoizing `Lazy` and `Inf` (design)

Status: design, not implemented. Today `Delay e` is lifted to a function
of one ignored argument and `Force t` to an application of `t` to an
erased value, so a delayed value is re-evaluated on every `force`
(TODO.md, "Semantics: `Lazy`/`Force`"). This document is the plan for
evaluating each delayed value at most once per cell.

## How much there is

Counted in upstream's `NamedCExp` (`--dumpcases`, 2026-10-01):

| | rc2 itself | idris2-lsp |
|---|---|---|
| definitions | 11,027 | 10,289 |
| `%delay Lazy` | 2,645 | 2,526 |
| `%delay Inf` | 925 | 748 |
| `%force Lazy` | 4,352 | 4,190 |
| `%force Inf` | 19 | 35 |
| top-level 0-ary definitions whose whole body is `%delay` | 218 | 214 |
| `%force (%delay ...)` | 0 | 0 |

What is delayed, in rc2 itself (idris2-lsp is close):

| `Lazy` body | count | `Inf` body | count |
|---|---|---|---|
| constructor | 673 | lambda | 469 |
| call | 648 | constructor | 369 |
| constant | 605 | call | 74 |
| lambda | 494 | | |
| variable | 141 | | |

Of the 4,352 `%force Lazy`, 4,219 force a call's result, most of them a
CSE'd top-level constant, `({csegen:N} [])`, whose body is a `%delay`.

After rc2's passes, about 2,800 (rc2) and 2,670 (idris2-lsp) of the
3,583 and 3,287 delay-lifted definitions are still in the final IR
(approximate: `.lifts` names are printed with `show`, the dump with
`dumpName`). In rc2 itself, 1,281 of them are built at run time as
closures with captures, 1,369 are static constant closures, and 93 were
folded into direct calls. 1,499 of their bodies allocate, 621 return a
constant, 693 do something else. `{csegen:17}`'s thunk returns a static
constant; `{csegen:189}`'s rebuilds a `Foldable` record and three
closures on every force. Memoization pays on the second shape.

## What Chez does

`LazyReason` is ignored by every Scheme backend.

- Default: `Delay e` is `(lambda () e)`, `Force t` is `(t)`; nothing is
  memoized.
- A 0-ary top-level definition whose body is `Delay e` becomes Scheme's
  own `(delay e)`, and a `Force` of a call to it `(force ...)`: those
  are evaluated once.
- `--directive lazy=weakMemo` memoizes every `Delay`, in a weak pair:
  the cached value can be collected and is then recomputed.

rc2 memoizes `Lazy` and `Inf` alike. There are no weak references under
reference counting; a cell and its value are freed as soon as nothing
refers to the cell, so a stream's evaluated prefix lives exactly as long
as something holds its head, as in call-by-need.

## Runtime representation

A lazy cell has `IDRIS2RC2_IORef`'s layout (`header`, `lock`, `v`) and
its own tag, `IDRIS2RC2_TAG_LAZY`, so a `Lazy (IORef a)` can't be taken
for a cell or the other way round.

- **Unevaluated**: `v` is a saturated closure (`filled == arity`) over
  the thunk function and its captures.
- **Evaluated**: `v` is the value. A value is never a saturated closure:
  `idris2rc2_trampoline` keeps dispatching until `filled < arity`, so a
  saturated closure in `v` always means "not evaluated yet".
- A thunk with no captures is a 0-ary closure; `idris2rc2_dispatchFn`
  already handles arity 0.
- `header.reserved` counts the threads currently evaluating the cell
  (see Force), so the cell stays the size of an IORef.

## `Force`

`idris2rc2_force(v)` borrows `v`:

1. Not a cell (tag is not `LAZY`): return `v` itself (dup'd). This is
   what lets a delayed value be a plain value (below).
2. A cell whose `v` is evaluated: return `v` dup'd. No lock: a value is
   written once and never replaced while the cell lives, so an acquire
   load of `v` is enough.
3. A cell whose `v` is a saturated closure:
   - If `reserved` is non-zero and the cell is on this thread's stack of
     cells being evaluated, abort with "a lazy value forces itself".
   - Otherwise, under the lock, re-read `v` and, if it is still the
     closure, dup the closure itself (not just its captures: another
     thread may store a result and drop the cell's reference to the
     closure at any moment after the lock is released). Release the
     lock, push the cell on this thread's stack, increment `reserved`,
     and evaluate through that reference: dup the captures and call
     the function, as `idris2rc2_dispatchWithExtra` does for a shared
     closure, then trampoline, then drop the reference. The closure
     stays in the cell, so another thread can evaluate it at the same
     time.
   - Pop, decrement `reserved`, take the lock. If `v` is still the
     closure, store the result (a release store) with one dup, so the
     cell and the caller each own a reference, and drop the cell's
     reference to the closure; if another thread stored first, drop
     this result and return the stored one dup'd. A thunk
     may run more than once when two threads force it together; that
     is accepted.
   - Evaluation never runs under the lock: a thunk that forces another
     cell, or this one, would deadlock.

## `Delay`

- **Already a value**: a `Delay` of a constant, a lambda, or a
  constructor whose fields are all variables or constants is replaced
  by that value, with no cell; `Force` returns it unchanged (case 1).
  None of these computes anything when evaluated. A constructor whose
  fields include a call or a `force` stays delayed: evaluating it early
  could diverge on an infinite structure.
- **A variable** stays delayed: it may itself be a lazy value
  (`Lazy (Lazy a)`), which `Force` must return, not force.
- **Everything else** allocates a cell holding a saturated closure.
- **0-ary top-level definitions whose body is a `Delay`** (218/214) get
  no cell. Every non-constant CAF is already memoized (`RMemoize`,
  `insertMemoize` in `RC2.idr`, `caf-memoization.md`), so a cell would
  memoize the same value twice. On the `NamedCExp`, before lifting:
  `x = Delay e` becomes `x = e` (memoized, or folded to a constant);
  `Force (x [])` becomes `x []`; any other reference `x []`, a lazy
  value passed on unforced, becomes `Delay (x [])`, so `e` is still not
  evaluated until something forces it. That `Delay` only calls the
  memoized CAF, and is a plain value when `x` folds to a constant.

## Ownership

- **The cell.** `RForce` borrows it; when the force is its last use the
  cell is dropped after the call (a `postDrop`, as on `ROp`). If that
  frees the cell, its reference to the value goes with it; the caller
  keeps its own.
- **The value.** After a force, the cell and the caller each own a
  reference, so a forced value is shared for as long as the cell lives.
  In-place constructor reuse fails on it unless the force was the
  cell's last use and freed the cell; that only costs speed, since
  uniqueness is checked at run time (TODO.md: skip reuse analysis on
  values whose cell outlives the force).
- **The closure.** The cell owns it until a result is stored. An
  evaluating thread holds its own reference (taken under the lock), so
  the cell dropping its reference mid-evaluation is harmless.
- **Tail calls.** Today a `Force` in tail position is an ordinary
  application and goes through the trampoline without growing the C
  stack. A memoizing `Force` has to store the result, so it is never a
  tail call: a long chain of thunks that each force the next grows the
  C stack by one frame per link. Accepted.
- **Cycles.** A cell whose value refers back to the cell can't be freed
  by reference counting. A thunk's captures exist before its cell does
  and Idris has no recursive `let`, so such a cycle can only arise
  through top-level definitions, which are never freed anyway; a
  thunk that forces its own cell aborts (Force, step 3).

## IR

- `RDelay fc lr thunk captures`: consumes `captures`, builds the cell.
  `RForce fc lr v`: borrows `v`. Both print in the dump (`delay`,
  `force`) and must be read back by `Language.RCExpr.Parser`.
- Lifting: the body of a `Delay` that isn't already a value is lifted
  to a thunk function taking its captures. A `Delay` whose body is a
  lambda is no longer merged with it (`LiftInfo`'s "params" case); the
  thunk returns the closure. `ArityRaise` relies on the merged shape
  and needs updating.
- `ConstFold`: `RForce` of an `RDelay` folds to the thunk's call, and
  `RForce` of a value known not to be a cell folds to the value.

## What the change touches

`RCExp`, lambda lifting (`RC.idr`), `ArityRaise`, `ConstFold`,
`SpecClosure` and `ClosureCtx` (they act on today's delay closures),
`DeadCode`, RC annotation and every RC pass (`RDelay` consumes,
`RForce` borrows), `Loop`/`TRMC`/`DualABI` (new node kinds to pass
through), `Emit`, the runtime (`IDRIS2RC2_TAG_LAZY`, `idris2rc2_force`,
teardown of a cell), `Pretty`, the rcexpr parser in rc2base,
`rcexpr-lint` and `rcexpr-diff`.

## Risks

- Delay arguments are plain closures today, so `ConstFold`'s apply fold
  and `SpecClosure` see through them (the 93 direct calls above). A cell
  hides them; the `ConstFold` rules above have to recover that.
  Compare `bench.sh` before and after.
- A delayed value that stays delayed costs two allocations (cell and
  closure) instead of one.
- `Force` crashes on anything built as a `Lazy`/`Inf` value without
  `Delay`. Check upstream's base and contrib for `believe_me` into
  `Lazy`/`Inf` and `%foreign` signatures mentioning them before
  enabling.

## Order of work

1. Runtime cell and `idris2rc2_force`, `RDelay`/`RForce`, lifting,
   RC annotation, Emit, dump and parser; every `Delay` gets a cell.
   Tests: a side effect runs once across two forces, `Inf` streams,
   `Lazy` of a function, two threads forcing one cell, a cell forcing
   itself.
2. Values instead of cells (constants, lambdas, value constructors),
   the rewrite of delayed top-level constants onto CAF memoization, the
   `ConstFold` rules; `bench.sh` against step 1 and against today.
3. TODO.md's "Semantics: `Lazy`/`Force`" entry is rewritten.
