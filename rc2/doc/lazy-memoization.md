# Memoizing `Lazy` and `Inf`

**Status: implemented, in two stages.** `RDelay`/`RForce` are their own
`RCExp` nodes, lowered to a lazy cell (`IDRIS2RC2_TAG_LAZY`) whose first
stored result `idris2rc2_force` shares with every later force (a race
between two threads forcing the same cell may run the thunk twice, but
only the first result stored is ever kept -- see "`Force`" below); a
`Delay` that computes nothing (a constant, a lambda, or a
constructor of atoms) is that value instead, with no cell at all.
`Compiler.RC2.LazyCaf` folds a 0-ary top-level `Delay` definition onto
the existing CAF memoization instead of giving it its own cell, and
`Compiler.RC2.LazyFold` turns a local delay forced exactly once into a
direct call of its thunk. See "Measured" and "Verification" below for
what changed and how it was checked.

## How much there is

Counted before either stage existed, in upstream's `NamedCExp`
(`--dumpcases`, 2026-10-01):

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

## Measured

rc2 compiling itself, counted in the final IR (`--directive
dumprcexpr`): before lazy cells existed at all (`Delay`/`Force` lowered
to a plain lambda and an application of it) compiling rc2 itself
produced 19,797 definitions and 3,993 closure applications (`apply` in
the dump). Stage 1 (every `Delay` gets a cell) produced 21,546
definitions, 3,765 `delay`s and 5,073 `force`s. Stage 2 (a `Delay` of a
constant/lambda/atom-constructor needs no cell, plus `LazyCaf` and
`LazyFold`) produced 19,616 definitions, 1,731 `delay`s, 202 `force`s,
and 3,454 closure applications. Compiling idris2-lsp under stage 2:
18,048 definitions, 1,676 `delay`s, 227 `force`s.

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
- `header.reserved` is 1 once a value is stored. Whether a cell is
  evaluated is decided by this flag, never by looking at `v`: an
  unevaluated `v` is a closure another thread may free at any moment.
  The cell stays the size of an IORef.

## `Force`

`idris2rc2_force(v)` borrows `v`:

1. Not a cell (tag is not `LAZY`): return `v` itself (dup'd). This is
   what lets a delayed value be a plain value (below).
2. An evaluated cell (an acquire load of `reserved` reads 1): return
   `v` dup'd, without the lock. A value is written once and never
   replaced while the cell lives.
3. A cell whose `v` is a saturated closure:
   - If the cell is on this thread's stack of cells being evaluated,
     abort with "a lazy value forces itself". The stack is only searched
     here, on the way to evaluating, which costs far more.
   - Otherwise, under the lock, re-read `v` and, if it is still the
     closure, dup the closure itself (not just its captures: another
     thread may store a result and drop the cell's reference to the
     closure at any moment after the lock is released). Release the
     lock, push the cell on this thread's stack, and evaluate through
     that reference: dup the captures and call
     the function, as `idris2rc2_dispatchWithExtra` does for a shared
     closure, then trampoline, then drop the reference. The closure
     stays in the cell, so another thread can evaluate it at the same
     time.
   - Pop, take the lock. If `reserved` is still 0, store the result
     with one dup, so the cell and the caller each own a reference, set
     `reserved` (a release store), and drop the cell's reference to the
     closure; if another thread stored first, drop
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
  memoize the same value twice. `Compiler.RC2.LazyCaf` (`applyLazyCaf`)
  does this rewrite on the whole program, before lifting, once, in
  `RC2.idr`'s `compileExpr` -- not per module, because another module's
  own reference to the same definition is out of sight by the time a
  per-module version would run. On the `NamedCExp`:
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
- **Tail calls.** `idris2rc2_force` has to store the thunk's result
  after it returns, so `Emit.idr` lowers `RForce` to a plain C call,
  `idris2rc2_force(v)`, never through the closure-dispatch trampoline an
  ordinary tail call uses -- a `Force` can never be a tail call. A long
  chain of thunks that each force the next therefore grows the C stack
  by one frame per link. Accepted.
- **Freeing.** A cell is torn down like a constructor field (deferred
  through `idris2rc2_teardown`'s loop), so freeing a long forced stream
  does not recurse once per element.
- **Cycles.** A cell whose value refers back to the cell can't be freed
  by reference counting. A thunk's captures exist before its cell does
  and Idris has no recursive `let`, so such a cycle can only arise
  through top-level definitions, which are never freed anyway; a
  thunk that forces its own cell aborts (Force, step 3).

## IR

- `RDelay fc lr thunk captures`: consumes `captures`, builds the cell.
  `RForce fc lr v`: borrows `v`. Both print in the dump (`delay`,
  `force`) and are read back by `Language.RCExpr.Parser`
  (`libs/rc2base`).
- Lifting: a `Delay` whose body isn't already a value calls `RC.idr`'s
  `lift` directly with no bound parameters of its own
  (origin `FromDelay lr`), so the resulting thunk takes only its
  captures, never merged with a lambda inside it. A `Delay` whose body
  is a lambda is one of the "already a value" cases above instead: it
  is lifted exactly as that lambda would be on its own, through
  `lambda` (which accumulates the lambda's own parameters before
  calling `lift` in turn, origin `FromLambda`) -- nothing in `LiftInfo`
  marks that it ever was a `Delay` at all.
- To `children`/`mapChildren`/`traverseChildren` (`RCExp.idr`),
  `RDelay`/`RForce` are leaves -- no `RCExp` child to recurse into -- so
  a pass that walks the tree only through those three needs no case of
  its own. `captures`/`v` are still locals, though, and anything that
  reads, renames or substitutes locals needs an explicit case even on a
  leaf: `freeLocalsR`, `countUsesR`, `mentionedLocalsAcc` and
  `directReads` (`RCExp.idr`) each have one, and so does `ConstFold`'s
  own `foldConst` substitution. A pass with a catch-all clause that
  forgets one of these would silently skip `RDelay`/`RForce` instead --
  the same silent-miss shape `caf-memoization.md`'s own "Limitations"
  section documents for `RMemoize`.

## `ConstFold`

`Compiler.RC2.ConstFold.foldConst` itself does not fold a `Force` of a
`Delay` -- its own `RDelay`/`RForce` cases only resolve `captures`/`v`
against whatever `resolveLocal` already knows (an alias or a folded
constant), the same as any other operand. Folding a `Force`-of-a-`Delay`
pair is
`Compiler.RC2.LazyFold`'s own job: it runs right after Early inline
(`RC2.idr`'s `rc2: Lazy fold`, the line `--timing 2` prints for it),
once inlining has had a chance to bring a `Delay` and its one `Force`
into the same function. `foldSingleForce` finds a `let v = delay
thunk caps` whose body uses `v` exactly once, as a `Force`'s own operand
and nowhere else, and replaces the whole `let`+body with a direct call
of `thunk` on `caps` -- the cell is never built. It runs before RC
annotation (no ownership yet to disturb) and before loop conversion (a
`Force` inside a loop could otherwise run many times for one binding).

## Known limitations

- A delayed value that stays delayed -- not folded away by `Delay`'s
  "already a value" cases above, nor by `LazyFold` -- costs two
  allocations (the cell, and the closure it holds until first forced)
  instead of one.
- `idris2rc2_force`'s first check is "not a cell" (see "`Force`" above),
  so forcing a value that was never built through `Delay` at all (a
  `believe_me`'d `Lazy`/`Inf`, or a `%foreign` signature mentioning
  either type) just returns it unchanged rather than crashing. Whether
  every such value in upstream's `base`/`contrib` is actually safe to
  hand to `force` this way has not been checked.

## Known upstream behaviour

Idris2's own compiler erases a `Lazy` in some places before rc2's
pipeline ever sees it -- confirmed for two shapes: a `Lazy` nested
inside a type argument (e.g. `IORef (Lazy Int)`), and a one-off `delay`
bound directly in `main`. For both, no `Delay`/`Force` node reaches rc2
at all, so nothing in this document applies to them. The exact upstream
pass responsible wasn't traced further.

## Verification

`rc2/tests/Test125LazyMemo` checks: a value forced twice through a
shared binding runs its side effect once; an `Inf` stream's tails each
evaluate once across two separate `take`s of the same stream; a long
forced stream (`iterate`/`index`) tears down without recursing once per
element; and several threads (`forkJoin`) forcing the same cell
together all read back the same value (consistency under a race, not a
count of how many times the thunk ran -- the test never reads how many
times its own side effect fired). Not covered by any test today: a
cell that forces itself (the runtime aborts with "a lazy value forces
itself" -- see "`Force`" above).

`rc2/tests/Test122LiftOrigin`'s `check.sh` checks lifting: a non-value
`Delay`'s thunk takes only its own captures (`delay Lazy`/`delay Inf`,
`params 0` in the `.lifts` dump), and a `Delay` of a lambda is lifted as
that lambda with no thunk and no cell at all (`lambda`, not `delay`, in
the same dump).

All tests pass; `bench.sh` shows no regression from this work.
