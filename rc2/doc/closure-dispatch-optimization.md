# Closure-dispatch fast path (`rc2/support/rc2/runtime.c`)

Implementation notes for a small, runtime-only optimization in
`idris2rc2_applyClosure` -- rc2's non-tail-call closure-application
entry point, used by generic higher-order code (`map`/`Foldable`/
interface-dictionary-method dispatch) and by `Force`'s own repeated
re-evaluation of a shared `Delay` closure. Unlike every other
`rc2/doc/*.md` companion document, this one touches no compiler pass
and no `RCExp` IR shape at all -- the change is confined entirely to
`rc2/support/rc2/runtime.c`, the hand-written C runtime library linked
into every rc2-compiled program. Written to let a future session (or a
future you) regain the safety reasoning without re-deriving it, since
it is easy to state the *wrong* version of this optimization (see
"Why `idris2rc2_tailcallApplyClosure` was deliberately left alone"
below) and have it look correct until a deep tail-recursive program
crashes.

## The problem

Every closure application in rc2 ultimately goes through one of two
entry points, chosen by `Compiler.RC2.Emit`'s `emitRC` case for `RApp`
(`rc2/src/Compiler/RC2/Emit.idr:1060-1065`):

```idris
emitRC (RApp fc _ closure arg) tailPosition = do
   closureStr <- rcVarToBoxedC closure
   argStr <- rcVarToBoxedC arg
   pure $ (case tailPosition of
       NotInTailPosition => "idris2rc2_applyClosure"
       InTailPosition    => "idris2rc2_tailcallApplyClosure") ++ "(\{closureStr}, \{argStr})"
```

`idris2rc2_tailcallApplyClosure` (`runtime.c:301-323`) grows a closure
by one argument. When the closure is uniquely owned, this is a plain
field write. When it's non-unique (shared, refcount > 1 -- e.g. a
partial application like `addN n` that `map` reuses across every list
element, or the closure `Force` re-applies against the same `Delay`
site every time it's forced), it must instead allocate a *new*
`IDRIS2RC2_Closure` via `idris2rc2_mkClosure`, `idris2rc2_dup` each
already-filled argument into it, and drop the original -- because some
other owner (the caller of `map`, the still-live `Delay` thunk) still
holds a reference to the original closure at its old arity and must
keep seeing it that way.

`idris2rc2_applyClosure` (`runtime.c:325-342`, before this change) was
simply:

```c
IDRIS2RC2_Value *idris2rc2_applyClosure(IDRIS2RC2_Value *c, IDRIS2RC2_Value *arg) {
  return idris2rc2_trampoline(idris2rc2_tailcallApplyClosure(c, arg));
}
```

-- i.e. it always immediately trampolines (dispatches) whatever
`idris2rc2_tailcallApplyClosure` hands back. That's fine when the
closure isn't yet saturated (the grown closure genuinely needs to
exist so a *later* application can keep filling it in), but when `arg`
is the closure's **final** argument, the freshly `mkClosure`'d object
built by the non-unique branch is used for exactly one purpose --
`idris2rc2_trampoline` dispatches it immediately -- and is then torn
down again right there. For a shared closure receiving its last
argument, the whole allocate-copy-dispatch-teardown round trip was
pure overhead: nothing outside this one call ever observes that grown
closure object.

## The fix: `idris2rc2_dispatchWithExtra` + a fast-path condition

A new helper, `idris2rc2_dispatchWithExtra` (`runtime.c:169-277`),
dups the closure's already-filled arguments and calls the target
`IDRIS2RC2_FUNn` function pointer directly, positioning `arg` last,
for every arity in the typed `1..20` range (the same range
`idris2rc2_dispatchClosure`, `runtime.c:90-157`, already switches on
for an already-saturated closure). Representative cases (1, 2, and 3
of the 20; the rest just extend the pattern with more `idris2rc2_dup`
calls):

```c
static inline IDRIS2RC2_Value *idris2rc2_dispatchWithExtra(IDRIS2RC2_Closure *c, IDRIS2RC2_Value *arg) {
  IDRIS2RC2_Value **const xs = c->args;
  switch (c->arity) {
  case 1:
    return (*(IDRIS2RC2_FUN1)c->fn)(arg);
  case 2:
    return (*(IDRIS2RC2_FUN2)c->fn)(idris2rc2_dup(xs[0]), arg);
  case 3:
    return (*(IDRIS2RC2_FUN3)c->fn)(idris2rc2_dup(xs[0]), idris2rc2_dup(xs[1]), arg);
  ...
  default:
    // Caller (idris2rc2_applyClosure) only reaches here for
    // 1 <= c->arity <= 20; the generic FUNSTAR arity is deliberately
    // out of scope for this fast path (falls through to the ordinary
    // mkClosure-based path instead).
    IDRIS2RC2_VERIFY(false, "idris2rc2_dispatchWithExtra: impossible arity %d", (int)c->arity);
    return NULL;
  }
}
```

`idris2rc2_applyClosure` itself now checks whether this shortcut
applies before falling back to the old path:

```c
IDRIS2RC2_Value *idris2rc2_applyClosure(IDRIS2RC2_Value *_c, IDRIS2RC2_Value *arg) {
  IDRIS2RC2_Closure *c = (IDRIS2RC2_Closure *)_c;
  if (!idris2rc2_isUnique(c) && c->arity - c->filled == 1 &&
      c->arity >= 1 && c->arity <= 20) {
    IDRIS2RC2_Value *result = idris2rc2_dispatchWithExtra(c, arg);
    idris2rc2_drop((IDRIS2RC2_Value *)c);
    return idris2rc2_trampoline(result);
  }
  return idris2rc2_trampoline(idris2rc2_tailcallApplyClosure(_c, arg));
}
```

The three-part condition mirrors exactly what would otherwise be true
of the closure right after the old path finished:

- `!idris2rc2_isUnique(c)` -- the unique case is already optimal (a
  plain field write in `idris2rc2_tailcallApplyClosure`); this fast
  path only targets the non-unique, `mkClosure`-would-otherwise-fire
  case.
- `c->arity - c->filled == 1` -- `arg` is the *final* argument, i.e.
  the grown closure would be immediately, unconditionally dispatched
  by the trampoline call that always follows. If more than one
  argument remains, the grown (still under-saturated) closure must
  actually be kept around for a future application, so the ordinary
  path is used.
- `c->arity >= 1 && c->arity <= 20` -- restricts to the typed `FUNn`
  range `idris2rc2_dispatchWithExtra` implements. See "Scope" below.

When the condition holds, the original closure's args are dup'd
straight into the target function call (mirroring exactly what
`idris2rc2_tailcallApplyClosure`'s non-unique branch would have copied
into its `mkClosure`'d replacement), the original closure is dropped
(it was never mutated, so this is an ordinary checked drop, not the
trampoline's own unconditional-decrement idiom), and the result is
trampolined as always. No `IDRIS2RC2_Closure` is ever allocated for
this application.

## Why `idris2rc2_tailcallApplyClosure` was deliberately left alone

This is the part of the change most worth getting right, and the
easiest part to get wrong by analogy: it might look like the same
"skip `mkClosure` when this is the last argument" shortcut should
apply equally well inside `idris2rc2_tailcallApplyClosure` itself. It
must not.

`idris2rc2_tailcallApplyClosure` is called directly -- not through
`idris2rc2_applyClosure` -- by generated code at genuinely
tail-position closure applications, exactly the `InTailPosition` arm
of `Compiler.RC2.RC2.Emit`'s `RApp` case quoted above
(`Emit.idr:1064-1065`). The entire reason a *separate* entry point
exists for that case, rather than always calling
`idris2rc2_applyClosure`, is that a tail-position application must
return a still-boxed, **undispatched** saturated closure back up the
C call chain, rather than dispatching it right there. Actual dispatch
happens later, in a separate, bounded `idris2rc2_trampoline` `while`
loop higher up the stack (`runtime.c:279-299`) -- the standard
trampoline technique this codebase relies on throughout to keep deep
tail-recursive Idris2 programs from growing the C stack unboundedly
(see `rc2/doc/loop-conversion.md`'s own "Tail-call -> `goto`" section
for the sibling mechanism -- a *self*- or *mutually*-tail-recursive
call is converted to a flat `goto` at compile time; a tail call
through an arbitrary, not-statically-known closure is instead bounced
through this same trampoline discipline at runtime, which is precisely
what `idris2rc2_tailcallApplyClosure`'s "return undispatched" contract
exists to support).

If the fast-path dispatch were added inside
`idris2rc2_tailcallApplyClosure` itself instead of only in
`idris2rc2_applyClosure`, a tail-position closure application reaching
the non-unique/final-argument branch would call `idris2rc2_dispatchWithExtra`
synchronously, from *within* `idris2rc2_tailcallApplyClosure`'s own
still-active C stack frame. If the target function itself tail-calls
back into another closure application landing in
`idris2rc2_tailcallApplyClosure` again -- exactly the shape a
self-referential, knot-tied closure produces (see
`Test68ClosureFastPathStackSafety` below) -- this turns what should be
a flat, iterative trampoline bounce into genuine, unboundedly-growing
C recursion, silently reintroducing stack-overflow risk for any deep
tail-recursive program built around a shared/non-unique closure.

`idris2rc2_applyClosure` is safe to optimize this way specifically
*because* it already unconditionally trampolines its own result
immediately, regardless of which branch runs -- that was already true
before this change. Short-circuiting the allocation inside it changes
*how* the final dispatch is reached, not *whether* or *when* it
happens: the caller of `idris2rc2_applyClosure` was already going to
get a fully-dispatched result back, synchronously, either way. Nothing
observable about dispatch timing changes; only the transient
allocation is removed.

## Laziness: no memoized state to disturb

`Force t` compiles to a plain `idris2rc2_applyClosure` call on
`Delay e`'s own closure (confirmed directly in generated C: a value
forced twice compiles to two independent
`idris2rc2_applyClosure(var_0, NULL)` calls with nothing cached
between them) -- see `TODO.md`'s existing "Semantics: `Lazy`/`Force`
defers evaluation but doesn't memoize" section for the full
derivation. Since `Force` already unconditionally dispatches
immediately on every call, with no "leave a saturated-but-undispatched
closure around for a later, separate re-use" state anywhere in the
codebase, there was nothing for this optimization to disturb here: the
fast path changes *how* that immediate dispatch is reached (skip the
allocation), never *whether* re-forcing recomputes (it still does,
exactly as before).

## Scope: arity 1..20 only

`idris2rc2_dispatchWithExtra` only implements the typed `FUNn` range,
matching `idris2rc2_dispatchClosure`'s own typed switch cases. A
closure with arity greater than 20 uses the generic, array-based
`IDRIS2RC2_FUNSTAR` calling convention instead (`idris2rc2_dispatchClosure`'s
own `default:` case) and is excluded from the fast-path condition in
`idris2rc2_applyClosure` (`c->arity <= 20`), falling through to the
original `idris2rc2_tailcallApplyClosure`-then-trampoline path
unchanged. This is a deliberate, known gap in this round's scope, not
an oversight -- see `TODO.md`'s "Performance: closure-dispatch fast
path doesn't cover arity > 20 (`FUNSTAR`)" entry for why it was left
out and what extending it would need.

## Reference tests

- **`Test66ClosureFastPathMap`** (`rc2/tests/Test66ClosureFastPathMap/`):
  `map (addN n) xs` over a 2000-element list -- `addN n` is a partial
  application (arity 2, filled 1) reused by `map` across every
  element, so it is non-unique at every application except possibly
  the last element's. Confirmed, via development-time instrumentation
  since removed, that the fast path fires exactly once per element.
- **`Test67ClosureFastPathDictDispatch`** (`rc2/tests/Test67ClosureFastPathDictDispatch/`):
  the same shape sourced from a genuine interface dictionary instead
  of a hand-written function -- `map (k +) xs` where `(k +)` is `Num`'s
  own `(+)` method extracted from a runtime dictionary and partially
  applied to a captured constant. Confirmed to fire the same way,
  once per element.
- **`Test68ClosureFastPathStackSafety`** (`rc2/tests/Test68ClosureFastPathStackSafety/`):
  the dedicated regression guard for the safety argument above -- a
  self-referential ("knot-tied") `IORef (Int -> Int)` whose stored
  closure is read back and re-applied in **tail position**,
  10,000,000 times. Every one of those applications is genuinely
  non-unique (the `IORef` itself retains a live reference to the
  closure on every iteration), so this is exactly the shape that would
  turn into unbounded C recursion if the fast path had been added to
  `idris2rc2_tailcallApplyClosure` instead of `idris2rc2_applyClosure`.
  Confirmed, via the same development-time instrumentation, to record
  **zero** fast-path hits (proving every application here goes through
  the untouched `idris2rc2_tailcallApplyClosure` path), and confirmed
  to complete in ~2.3s without a stack overflow.

Full `verify.sh` run at the time this landed: 87 passed, 0 known, 0
failed, valgrind clean.
