# `RApp` N-ary generalization: collapsing a curried closure-apply chain into one dispatch

## Motivation

`rc2/doc/speculative-closure-specialization.md`'s own motivation section
and `TODO.md`'s "Performance: interface-dictionary method dispatch stays
boxed even when the concrete instance is known" entry both trace the
same real cost to the same root shape: a curried multi-argument
application against a *boxed closure value* (an interface-dictionary
method, or any ordinary higher-order function argument) compiles to a
chain of single-argument `RApp` nodes, each going through
`idris2rc2_applyClosure` independently. For `HashAlgorithm`'s `feed8`
(arity 2, `acc -> byte -> acc'`), this means two full boxed dispatches
per byte, and -- confirmed in the generated C -- a real heap-allocated
intermediate `IDRIS2RC2_Closure` for the first (still-partial)
application, even though the whole call is always immediately fully
applied.

Both prior investigations proposed *specializing*/*cloning* the
function that holds the `apply` call (`SpecClosure`'s own closure-
argument specialization, or a hypothetical per-dictionary clone of
`feedCharOfString`) to resolve the boxed dispatch to a direct call.
This document instead resolves the *cheaper*, unconditionally-safe
half of the same cost -- the chain of one-at-a-time boxed dispatches
itself -- without cloning anything, so it helps regardless of whether
the closure's ultimate target is statically known at all. It composes
with (doesn't replace) a future `SpecClosure`-style target-specific
optimization: even a fully generic, runtime-only-known closure benefits
from applying its `missing` remaining arguments in one dispatch instead
of `missing` chained ones.

## The chosen design: generalize `RApp` itself, not a new node

Considered and rejected: adding a new `RAppClosureN` constructor next
to `RApp`. Rejected because `Compiler.RC2.RAppName` (a *named*-function
call) already takes `List RCLocal` for exactly this reason -- a named
call's arity is always known up front. `RApp` (a *closure* call) being
stuck at exactly one argument is the odd one out, not the norm, in this
GADT. Generalizing it:

```idris
RApp : FC -> (lazy : Maybe LazyReason) -> RCLocal -> List RCLocal -> RCExp
```

is strictly *less* code than adding a sibling node: every existing
`RApp fc lazy c a` clause across the pipeline (`RCExp.idr`'s own
`freeLocalsR`/`countUsesR`/`foldRCNamesL`, `ConstFold`, `Sink`,
`ConAltNative`, `Pretty`, `LateInline`, `SpecClosure`, `RC2.rcSizeOf`,
`Emit`, `Loop`, `RC.idr`'s own Phase 1/2) widens in place to `RApp fc
lazy c args`/`c :: args` -- a new node would need a brand-new clause in
most of those same files instead, on top of the widening this needs
anyway wherever ownership logic treats `c`/`a` as a 2-element list
(`splitBorrows`/`wrapDups`, `countInvariantDups`/`wrapInvariantDups`,
`countDupsNeeded`/`wrapNDups`). The singleton case `RApp fc lazy c [a]`
is byte-for-byte today's shape -- fully backward compatible in spirit,
Idris2's own exhaustiveness checking catches every site that still
needs updating.

## Where the args list actually comes from: Phase 1, not a later pass

A separate "chain-collapsing pass" (walking `RLet`-threaded single-arg
`RApp`s back into one, the way `SpecClosure.chainArgs` already does
for its own narrower purpose) was considered and rejected as
unnecessary. `Compiler.LambdaLift`'s own `unload` (the function that
turns a source-level `f a1 a2 a3` into `Lifted`) already builds exactly
a nested-`LApp` nested structure:

```idris
unload : FC -> (lazy : Maybe LazyReason) -> Lifted vars -> List (Lifted vars) -> Core (Lifted vars)
unload fc _ f [] = pure f
-- only outermost LApp must be lazy as rest will be closures
unload fc lazy f (a :: as) = unload fc Nothing (LApp fc lazy f a) as
```

`f a1 a2 a3` becomes `LApp fc Nothing (LApp fc Nothing (LApp fc lazy0 f
a1) a2) a3` -- the *original* `lazy` tag sits on the *innermost* `LApp`
(the one directly wrapping the true callee `f`), every application
after the first carries `Nothing` (`unload`'s own comment: "rest will
be closures", i.e. already-applied intermediate values, never
independently lazy). This nested shape reaches `Compiler.RC2.RC`'s own
Phase 1 (`normalize`) completely intact -- `RC.idr` is upstream's own
`Lifted` consumer, nothing between `unload` and `normalize` flattens
it. `normalize`'s existing `LApp` clause therefore only has to walk
its *own* argument down to the non-`LApp` base once, instead of a
second pass rediscovering the same chain later from `RLet`-threaded
`RApp`s:

```idris
||| Walks a nested LApp spine (built by Compiler.LambdaLift's own
||| `unload`, innermost-lazy) down to its non-LApp base, collecting
||| args in original left-to-right order. The base's own `lazy` tag is
||| `unload`'s "only outermost [i.e. innermost-built] LApp must be
||| lazy" one; every LApp above it carries Nothing by construction, so
||| looking at the *deepest* LApp's own lazy field is correct, not
||| approximate.
collectAppChain : Lifted vars -> (Lifted vars, Maybe LazyReason, List (Lifted vars))
collectAppChain (LApp _ lazy c a) =
    case c of
         LApp _ _ _ _ => let (base, lazy0, args) = collectAppChain c in (base, lazy0, args ++ [a])
         _             => (c, lazy, [a])
collectAppChain e = (e, Nothing, [])   -- unreachable from normalize's own LApp guard; total for reuse elsewhere
```

`normalize env (LApp fc lazy c a)`'s existing body (`bindOne env c
(\cl => bindOne env a (\al => pure $ RApp fc lazy cl al))`) becomes:

```idris
normalize env e@(LApp fc _ _ _) =
    let (base, lazy0, args) = collectAppChain e
    in bindOne env base (\basel => bindMany env args (\argsl => pure $ RApp fc lazy0 basel argsl))
```

`fc` here is the *outermost* application's own source position (already
what every other multi-arg case, `LAppName`/`LUnderApp`/`LCon`, uses for
its own whole-node `fc`), consistent with treating the whole chain as
one `RApp` node.

This means **no distinct closure target needs to be known at compile
time at all** for the collapse to happen -- unlike `SpecClosure`, this
isn't speculative or profitability-gated, it's a straight structural
translation choice made once, at the point `Lifted` already hands rc2
the full spine. Every curried application against a closure value in
the entire program gets this for free, dictionary or not.

## Runtime side: reuse the existing arity-keyed switch, add no new one

`rc2/support/rc2/runtime.c` already has exactly the pattern this needs
for "share an implementation across a small closed range of arities,
fall back generically above it": `idris2rc2_dispatchClosure`'s own
`switch (c->arity)` (0-20, `default` to the array-passed `FUNSTAR`
calling convention). Its cases only ever read `c->args[i]` -- nothing
about them is closure-specific.

**Step 1**: extract that switch to operate on `(fn, arity, xs)`
directly instead of a `Closure*`, so it's reusable from a second
call site with zero duplication:

```c
static inline IDRIS2RC2_Value *idris2rc2_dispatchFn(void *fn, uint8_t arity, IDRIS2RC2_Value **xs) {
  switch (arity) { /* unchanged body, still 0-20 + default */ }
}
static inline IDRIS2RC2_Value *idris2rc2_dispatchClosure(IDRIS2RC2_Closure *c) {
  return idris2rc2_dispatchFn(c->fn, c->arity, c->args);
}
```

**Step 2**: `idris2rc2_applyClosureN(IDRIS2RC2_Value *_c, IDRIS2RC2_Value **newArgs, uint8_t n)`:

```c
IDRIS2RC2_Value *idris2rc2_applyClosureN(IDRIS2RC2_Value *_c, IDRIS2RC2_Value **newArgs, uint8_t n) {
  IDRIS2RC2_Closure *c = (IDRIS2RC2_Closure *)_c;
  uint8_t remaining = c->arity - c->filled;

  if (n == remaining && c->arity <= 20) {
    // Saturating in one shot: no intermediate closure at all, dup the
    // existing filled args into a stack scratch buffer alongside the
    // new ones, then reuse the *same* switch dispatchClosure uses.
    IDRIS2RC2_Value *xs[20];
    for (uint8_t i = 0; i < c->filled; ++i) xs[i] = idris2rc2_dup(c->args[i]);
    for (uint8_t i = 0; i < n; ++i) xs[c->filled + i] = newArgs[i];
    IDRIS2RC2_Value *result = idris2rc2_dispatchFn(c->fn, c->arity, xs);
    idris2rc2_drop((IDRIS2RC2_Value *)c);
    return idris2rc2_trampoline(result);
  }

  if (n < remaining) {
    // Still partial after all n: exactly tailcallApplyClosure's own
    // unique-in-place / grow-by-copy split, generalized from +1 to +n.
    if (idris2rc2_isUnique(c)) {
      for (uint8_t i = 0; i < n; ++i) c->args[c->filled + i] = newArgs[i];
      c->filled += n;
      return (IDRIS2RC2_Value *)c;
    }
    IDRIS2RC2_Closure *nc = idris2rc2_mkClosure(c->fn, c->arity, c->filled + n);
    for (uint8_t i = 0; i < c->filled; ++i) nc->args[i] = idris2rc2_dup(c->args[i]);
    for (uint8_t i = 0; i < n; ++i) nc->args[c->filled + i] = newArgs[i];
    idris2rc2_drop((IDRIS2RC2_Value *)c);
    return (IDRIS2RC2_Value *)nc;
  }

  // n > remaining (over-application, e.g. a curried call whose base
  // itself returns another function still needing more args), or
  // arity > 20 (FUNSTAR territory, out of scope for the fast lane):
  // fully generic, already-correct one-at-a-time fallback. Bounded by
  // `remaining` iterations at most for the over-application case.
  IDRIS2RC2_Value *it = _c;
  for (uint8_t i = 0; i < n; ++i) it = idris2rc2_applyClosure(it, newArgs[i]);
  return it;
}
```

No new per-arity switch, no per-`n` code generation, no cap on `n`
beyond what the fallback loop already handles unconditionally -- the
20-arity cap that matters is `dispatchFn`'s own existing one, shared
by both call sites, changed in exactly one place if it's ever raised.

## Emit-side change

`Compiler.RC2.Emit`'s `RApp` clause (`emitRC sink (RApp fc _ closure
arg) tailPosition`) dispatches on `length args`:

- `[a]` (the overwhelmingly common case, and every occurrence that
  predates this change): identical codegen to today,
  `idris2rc2_applyClosure`/`idris2rc2_tailcallApplyClosure`.
- `a :: rest` (two or more): build a small on-stack `IDRIS2RC2_Value
  *argsN[]` from the emitted operands, call `idris2rc2_applyClosureN`
  (`NotInTailPosition`) -- a tail-position N-ary runtime variant is
  future work, not attempted here (`idris2rc2_tailcallApplyClosure`'s
  own "return an undispatched closure for the caller's own tail loop"
  contract would need its own N-ary sibling; `applyClosureN` above
  always dispatches immediately, mirroring `applyClosure` not
  `tailcallApplyClosure`). `InTailPosition` instead chains the
  existing single-argument primitives -- but **only the last hop** may
  use `idris2rc2_tailcallApplyClosure`; every earlier one must go
  through `idris2rc2_applyClosure`. A first attempt chained
  `tailcallApplyClosure` for every hop and crashed for real
  (`Test1Basics`, `free(): invalid size`): `tailcallApplyClosure`
  deliberately never dispatches even once `filled == arity` (that's
  its whole contract, letting a tail loop keep accumulating without
  paying for a dispatch+trampoline every step), so if an *earlier* hop
  happens to complete the closure it's applied to, the *next* chained
  `tailcallApplyClosure` call still tries to grow it further -- writing
  one slot past its allocation. This isn't hypothetical: `Prelude.IO`'s
  own `io_bind`-fused worker (`Compiler.Inline`'s special-cased
  desugaring) routinely passes an *already one-argument-short-of-
  complete* closure into one of these chain positions, so the first of
  two chained applies to it already saturates it. `idris2rc2_applyClosure`
  doesn't have this problem -- its own fast path dispatches immediately
  once saturated and hands the chain whatever fresh value comes back,
  exactly matching what the pre-merge single-arg-`RApp`-at-a-time chain
  already did node-by-node.

## A partial simplification this exposes: `SpecClosure.chainArgs`

`SpecClosure.idr`'s own `chainArgs` exists to rediscover a chain of
applies reaching exactly `missing` args, walking an `RLet`-threaded
sequence of `RApp`s. A source-level `v x y` (one syntactic
application) now reaches `SpecClosure` as one already-merged `RApp v
[x, y]` node (`collectAppChain` merges it at Phase 1, before
`SpecClosure` ever runs) -- exactly `feed8`-shaped code, this
document's own motivation -- so `chainArgs`'s single-hop, exact-match
case becomes the common one. It does *not* fully collapse, though: a
genuinely let-bound intermediate partial application written in the
source itself (`let partial = v x in ... partial y ...`, two
syntactically separate applications with real, independent bindings)
still produces two distinct `RApp` nodes threaded by an `RLet` --
`collectAppChain` only merges *directly nested* `LApp`s, and an
explicit `let` in between is a genuine break in that nesting, not an
artifact this change removes. `chainArgs` keeps its `RLet`-threaded
fallback, generalized so each hop can now contribute however many args
its own `RApp` carries (no longer always exactly one):

```idris
chainArgs : RCLocal -> Nat -> RCExp -> Maybe (List RCLocal)
chainArgs v missing (RLet _ t _ (RApp _ _ c args) cont) =
    if c == v && length args < missing
       then (args ++) <$> chainArgs (RCLoc t) (missing `minus` length args) cont
       else Nothing
chainArgs v missing (RApp _ _ c args) =
    if c == v && length args == missing then Just args else Nothing
chainArgs _ _ _ = Nothing
```

## Ownership/dup generalization

Every site currently treating `RApp`'s two operands as the literal list
`[c, a]` widens to `c :: args`, no behavior change for the semantics
each already implements (just the arity of the list it operates over):

- `RC.idr`'s Phase 2 `annotate`: `splitBorrows natives owned [c, a]` -> `splitBorrows natives owned (c :: args)`.
- `ConAltNative.idr`'s `reannotateFieldOwnership`: `countDupsNeeded fid owned [c, a]` -> `countDupsNeeded fid owned (c :: args)`.
- `Loop.idr`'s `dupInvariantBoxed`/`existsInvariantUse`/`renameRCExp`: same widening.
- `Sink.idr`'s `genuinelyUsedR`, `LateInline.idr`'s `hasNonNativeUse`, `RCExp.idr`'s `freeLocalsR`/`countUsesR`/`foldRCNamesL`: same.

None of these need new *logic*, only the operand-list literal widened
-- confirmed by reading every call site before writing this document
(see "Files" below for the exact locations).

## Verification

`rc2/tests/verify.sh`: 85 passed, 0 known, 0 failed, valgrind included
(clean after fixing two real bugs found by it -- see "Bugs found and
fixed" below).

Re-benchmarked `idris2-missing-containers`' own `test/src/Main.idr`
(same workload `speculative-closure-specialization.md`'s own
motivation section used, `write`/`read` through `feedCharOfString` ->
`feed8`, still boxed/undirected-dispatch since `SpecClosure` doesn't
reach a dictionary method -- see that document and `TODO.md`'s
"interface-dictionary method dispatch stays boxed" entry), 3 runs each,
against the already-landed `HasIO`-removal baseline (`write` ~8.14s,
`read` ~0.807s over ~986k/~99k entries respectively):

| | HasIO-removal baseline | + this change | further improvement |
|---|---|---|---|
| write | ~8.14s | ~7.63s | ~6.3% |
| read | ~0.807s | ~0.749s | ~7.2% |

Consistent with the design's own goal: collapsing `feed8`'s two
chained boxed dispatches (and the intermediate closure allocation
between them) into one saturating call, with zero code duplication and
no dependency on knowing the dictionary's identity at compile time.

## Bugs found and fixed during implementation

Both found by `rc2/tests/verify.sh` itself (not caught in review),
confirmed via `valgrind --track-origins=yes` and a temporary
`fprintf`-instrumented runtime build against a from-scratch `git
stash`-compared before/after `--directive dumprcexpr` for a minimal
repro (`ref <- newIORef 0; modifyIORef ref (+1); v <- readIORef ref;
printLn v`) once the crash's own stack trace alone wasn't enough to
localize it:

- **`idris2rc2_applyClosureN`'s saturating fast path over-dup'd a
  unique closure's own existing args.** The first version dup'd
  `c->args[0..filled-1]` unconditionally before dispatching, then
  unconditionally `idris2rc2_drop`'d `c` afterward -- correct for the
  non-unique case (mirroring `idris2rc2_applyClosure`'s own existing
  fast path exactly), but for a *unique* closure this double-counted
  every filled arg: the dup'd copy gets consumed by the dispatched
  call as intended, but the *original* reference, still sitting in
  `c->args[i]`, then gets a second, spurious drop when `c` itself is
  torn down -- an early free with the object still logically in use.
  Fixed by splitting on `idris2rc2_isUnique(c)` the same way
  `idris2rc2_tailcallApplyClosure` already does: unique transfers
  `c->args[i]` into the dispatch directly (no dup) and frees only the
  closure *shell* afterward (mirroring `idris2rc2_trampoline`'s own
  teardown); non-unique keeps the original dup-then-drop. Manifested
  as `Test1Basics` printing nothing at all and crashing with glibc's
  `free(): invalid size` (heap corruption detected far downstream of
  the actual bad free, at a whole unrelated later `idris2rc2_trampoline`
  call) -- confirmed as *this* bug specifically via a minimal isolated
  3-arg-closure repro that worked, ruling out the basic saturating-call
  mechanism, before the unique-vs-non-unique distinction was reconsidered.
- **`Emit.idr`'s `InTailPosition` multi-arg fallback chained
  `idris2rc2_tailcallApplyClosure` for every hop, including
  intermediate ones.** `tailcallApplyClosure`'s own contract
  deliberately never dispatches even once `filled == arity` (that's
  what makes it safe/cheap to chain within one tail loop's own
  accumulation) -- so chaining it blindly assumes no *intermediate*
  hop can ever complete the closure it's applied to before the chain's
  final argument. That assumption is false: `Prelude.IO`'s own
  `io_bind`-fused worker (`Compiler.Inline`'s special-cased
  desugaring, confirmed by reading `PrimIO.idr`'s own `io_bind`) hands
  one of these chain positions an *already one-argument-short*
  partially-applied closure (`Data.IORef`'s own curried worker), so
  the chain's first hop to it already saturates it -- the second,
  still-chained `tailcallApplyClosure` call then wrote one slot past
  its now-full allocation. Confirmed via `valgrind --track-origins=yes`
  pinpointing the exact "0 bytes after a block of size 40" invalid
  write, then a temporary `fprintf` in both `idris2rc2_applyClosureN`
  and `idris2rc2_tailcallApplyClosure` showing the exact
  arity/filled/n sequence at the crash. Fixed by chaining
  `idris2rc2_applyClosure` (which *does* dispatch-and-continue safely
  when a hop saturates, handing the next hop whatever fresh value
  comes back) for every hop except the last, which alone stays
  `tailcallApplyClosure` -- exactly what the pre-merge, one-`RApp`-per-
  hop code already did node-by-node. Manifested as the same
  `free(): invalid size` crash, reached through a different call path
  (`Test1Basics`' own three chained `IORef` operations in its `do`
  block).

Both bugs were specific to code this change introduced (the
`applyClosureN` runtime function and the `Emit.idr` multi-arg `RApp`
cases); the underlying merge itself (`collectAppChain`, verified via
side-by-side `--directive dumprcexpr` diffing against the pre-change
compiler for the same minimal repro) produced byte-for-byte the same
argument values in the same order as the original chained-single-`RApp`
form -- the two bugs above were in how those args got *applied*, not
in what got collected.

## Open questions / risks

- **Tail-position N-ary apply**: not attempted here. `RApp` in
  `InTailPosition` still emits `idris2rc2_tailcallApplyClosure` per
  argument today; giving that its own N-ary form (returning an
  undispatched, correctly-grown closure for the enclosing loop's own
  trampoline) is a natural follow-up once this lands, not a
  precondition for it -- the `NotInTailPosition` fast path is where
  `feed8`-shaped hot loops actually spend their time per the profiling
  this document's own motivation section cites.
- **Interaction with `SpecClosure`**: orthogonal and composable, not
  overlapping -- `SpecClosure` still resolves *which* function a
  closure argument is (when knowable) and calls it directly, skipping
  `idris2rc2_applyClosureN` entirely for that call site; this change
  only makes the case `SpecClosure` doesn't (and, per the dictionary
  investigation, structurally can't without cloning) reach cheaper.
- **`missing` vs. `args` length mismatch at a merged call site**: by
  construction from `collectAppChain`, `args` is exactly the source
  program's own curried application list -- no static arity claim is
  made or required; `idris2rc2_applyClosureN`'s three-way split (`==`/
  `<`/`>` `remaining`) is unconditionally safe for any `n`, same
  guarantee `idris2rc2_applyClosure`'s existing single-argument version
  already provides one hop at a time.

## Files

- `rc2/src/Compiler/RC2/RCExp.idr` -- `RApp`'s own declaration,
  `freeLocalsR`/`countUsesR`/`foldRCNamesL`.
- `rc2/src/Compiler/RC2/RC.idr` -- Phase 1 `normalize`'s `LApp` clause
  (`collectAppChain`, new), Phase 2 `annotate`'s `RApp` clause.
- `rc2/src/Compiler/RC2/ConstFold.idr`, `Sink.idr`, `ConAltNative.idr`,
  `Pretty.idr`, `LateInline.idr`, `Loop.idr`, `RC2.idr` (`rcSizeOf`) --
  mechanical operand-list widening, no logic change.
- `rc2/src/Compiler/RC2/SpecClosure.idr` -- `chainArgs` simplification
  (see above).
- `rc2/src/Compiler/RC2/Emit.idr` -- `RApp`'s codegen, `applyClosure`
  vs. `applyClosureN` dispatch on `length args`.
- `rc2/support/rc2/runtime.c`/`runtime.h` -- `idris2rc2_dispatchFn`
  (extracted), `idris2rc2_applyClosureN` (new).
- `rc2/doc/speculative-closure-specialization.md`,
  `TODO.md`'s "interface-dictionary method dispatch stays boxed" entry
  -- the investigations this design responds to; not superseded by it,
  the "clone per known target" idea documented there remains a
  separate, still-open follow-up for the cases where the closure's
  identity is *and stays* statically known.
