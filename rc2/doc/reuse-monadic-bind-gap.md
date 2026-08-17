# Constructor reuse doesn't reach across a monadic-bind continuation (investigated, not pursued)

Write-up of an investigation into why `Compiler.RC2.Reuse` (see
`rc2/doc/reuse-analysis.md`) fails to fire on a real, benchmark-dominant
piece of code, and why the fix that first looked promising turned out
not to apply here. No code changed as a result of this investigation --
this document exists so a future session doesn't have to re-derive any
of it.

## Motivation

After `Compiler.RC2.ConAltNative` shipped (`rc2/doc/con-alt-native.md`),
re-measuring the external `idris2-missing-containers` package's
`benchmarkHashMap` benchmark showed almost no change (rc2 ran ~36%
faster than RefC post-`ConAltNative`, vs. ~31% pre -- within likely
measurement noise). `benchmarkHashMap`'s `write` phase alone accounts
for ~10s of its ~16.5s total. Its hot path is
`Data.Container.Internal.IOHashSet.replaceL2`
(`install/idris2-missing-containers/src/Data/Container/Internal/IOHashSet.idr`,
inside `runIOHashSet`'s own `where` block), a self-recursive bucket-list
(a plain `List t`) walk:

```idris
replaceL2 : List t -> io (r, Maybe (List t))
replaceL2 [] = do ...
replaceL2 xs@(x::xs') with (decEq k (keyfunc hs x))
  _ | Yes prf = case !(found (x ** prf)) of
    NoOp r => pure (r, Nothing)
    Remove r => pure (r, Just xs')
    InsertOrReplace r v => pure (r, Just (v::xs'))
  _ | No _ = do
      (r, Just zs) <- replaceL2 xs'
        | r@(_, Nothing) => pure r
      pure (r, Just (x::zs))
```

Both branches destructure `x::xs'` and reconstruct a same-shape `::`
cell (`v::xs'` swapping the head; `x::zs` keeping the head, rebuilding
the tail) -- textbook constructor-reuse-in-place material. Generated C
for the real package build showed no `reuse_`-prefixed variable
anywhere near either reconstruction: every bucket-list step allocates a
brand-new cons cell via `idris2rc2_newConstructor`, and the original
cell is unconditionally freed. This document is the investigation into
why.

## First hypothesis: `with`-blocks lift into a separate function (refuted as stated)

`with` in Idris2 desugars into a separate top-level definition (an
auxiliary "with-block" function), elaborated well before rc2 ever sees
the `Lifted` IR. The first hypothesis was that this call boundary is
what blocks `Reuse`.

A minimal repro confirmed *half* of this: two versions of the same
shape, one with `with`, one with an ordinary `case`, both compiled with
`idris2-rc2 --cg rc2`:

```idris
-- with-block version: no reuse_ variable anywhere in the generated C.
replaceL2 : Nat -> String -> List KV -> List KV
replaceL2 k v [] = [MkKV k v]
replaceL2 k v (x::xs) with (decEq k (key x))
  replaceL2 k v (x::xs) | Yes _ = MkKV k v :: xs
  replaceL2 k v (x::xs) | No _ = x :: replaceL2 k v xs

-- ordinary-case version: reuse_var_2 fires cleanly in both branches.
replaceL2 : Nat -> String -> List KV -> List KV
replaceL2 k v [] = [MkKV k v]
replaceL2 k v (x::xs) =
  case decEq k (key x) of
       Yes _ => MkKV k v :: xs
       No _ => x :: replaceL2 k v xs
```

This looked like a clean fix: rewrite `replaceL2` to use `case` instead
of `with`. Applying that rewrite to the real library
(`install/idris2-missing-containers`, temporarily, for measurement
purposes only -- reverted afterward with `git checkout --`, never
committed) and re-measuring `bench.sh --missing-containers` under
identical conditions gave **no significant difference** (14.62s
`with`-version vs. 14.43s `case`-version, both freshly re-timed; the
16.53s figure from the `ConAltNative` measurement session was simply
noisier machine conditions, not a real baseline to compare against).
Inspecting the generated C for the rewritten library confirmed why:
`idris2rc2_newConstructor` is still called unconditionally at the
reconstruction sites -- **no `reuse_` variable appears there either.**

So `with` vs. `case` isn't the actual variable. The real function
(`runIOHashSet`, and `replaceL2` inside its `where` block) is
`HasIO io =>`-polymorphic and uses `!`-bang notation
(`case !(found (x ** prf)) of ...`) -- and that's true whether the
outer dispatch is written with `with` or `case`. That's what actually
matters, per the next section.

## Root cause, confirmed via `--directive dumprcexpr`

Reverse-engineering generated C left real ambiguity (see the "coincidental
reuse" aside below), so the actual mechanism was confirmed directly from
the RCExp IR (`idris2-rc2 --cg rc2 --directive dumprcexpr ...`, producing
a `.rcexpr` file next to the `.c` output -- see `rc2/doc/reading-the-ir.md`).
A repro matching the real shape (`HasIO io`-polymorphic, bang-notation
on an effectful callback):

```idris
replaceL2 : HasIO io => Nat -> String -> (Nat -> io Bool) -> List KV -> io (List KV)
replaceL2 k v found [] = pure [MkKV k v]
replaceL2 k v found (x::xs') =
  case decEq k (key x) of
       Yes _ => case !(found k) of
                     True => pure (MkKV k v :: xs')
                     False => pure (x :: xs')
       No _ => do
         zs <- replaceL2 k v found xs'
         pure (x :: zs)
```

dumps to (abbreviated, showing only the outer function's `CONS` alt):

```
def Main.replaceL2  (fun args=["v0:Boxed", ..., "v4:Boxed"] ret=Boxed)
  case v4 of                              -- v4 = xs
    _builtin.CONS args=[v16, v17] ->      -- destructure x::xs'
      drop [v4]                           -- unconditional -- no reuseOffer
      ...
      let v30 : Boxed =
        partial Main.{replaceL2:0} missing=1 [v16, v17, v0, v1, v2]
      apply v26 v30
```

`v4` (the list cell) is dropped unconditionally, never offered for
reuse. `Compiler.RC2.Reuse`'s eligibility check
(`resolveAlt` in `rc2/src/Compiler/RC2/Reuse.idr`) requires
`usedConstructorsR` to find a literal `RCon` of the matching name
somewhere in the alt's own body (`RCExp.idr:436-451`) -- and
`usedConstructorsR` returns `empty` for every call form (`RApp`,
`RAppName`, `RUnderApp`), by explicit design (`Reuse.idr`'s own module
note: "a call is always a dead end here -- this is a purely local,
intraprocedural analysis; whatever the callee does is invisible"). The
actual reconstruction happens inside `Main.{replaceL2:0}` -- a
*separate* lambda-lifted definition, invisible to this check. And
critically, the call reaching it is `partial ... missing=1`: **a
genuine partial application**, not a fully-saturated call -- because
`case !(found k) of ...` desugars through `>>=`, whose signature
(`io a -> (a -> io b) -> io b`) requires the continuation to be built as
a first-class closure value. `io` stays a polymorphic type variable
here (never monomorphized to concrete `IO`), so rc2 has no static
guarantee the continuation is invoked exactly once -- a syntactically
ill-behaved `Monad`/`HasIO` instance could invoke it zero or several
times, and the compiler has to be correct for all of them.

## The user's proposed fix, and why it doesn't reach this case

The natural next idea: instead of extending `Reuse` to be
interprocedural (a much bigger effort), inline any lifted definition
that has exactly one call site *and* is invoked via a fully-saturated
direct call (never captured as a partially-applied closure, since that
can't be bounded to "called exactly once" without deeper effect
analysis) -- before `Reuse` runs, so it sees one merged function body
instead of several. This is sound and considerably simpler than making
`Reuse` itself cross-procedural.

It doesn't help here, though: the RCExp dump shows the actual call is
`partial Main.{replaceL2:0} missing=1 [...]` -- not fully saturated.
The "exactly one call site" property does hold for these lifted
case-block helpers (confirmed empirically too: each of
`replaceL2`'s own lifted helpers appears exactly 3 times in the real
package's generated C -- prototype + definition + one call site, vs. 4
for the genuinely-recursive named `replaceL2` itself, which has two:
initial + tail call), but the *fully-saturated* half of the criterion
fails, specifically because of the monadic-bind continuation, not
because of any ambiguity about call count.

## Aside: reuse still fires, just on the wrong cell

Reading the real package's generated C initially suggested reuse *was*
firing inside the lifted helpers (`reuse_var_0`/`reuse_var_4`,
`idris2rc2_isUnique` checks, present and real). Tracing it through the
RCExp dump clarified what's actually being reused: rc2 represents *any*
single-constructor, 2-field boxed value (a `List` cons cell, but also,
e.g., a two-method interface dictionary record) using the same
`_builtin.CONS`-tagged physical shape, and `Reuse`'s matching is by
that shape/name, not by original source-level type identity. In the
lifted helper, an interface-dictionary value that's structurally
identical in shape to a cons cell, and *is* fully local to that one
function, gets its own legitimate local reuse offer -- which happens to
get consumed building the new `x::zs`/`v::xs'` cell. This *does* save
an allocation, just not the one this investigation was chasing: the
*original* list cell (`v4` above) was already unconditionally dropped
one level up, before this helper ever ran. So there's still a wasted
alloc+free pair for the original cell; the dictionary-shaped reuse is a
bonus that partially, coincidentally offsets it, not evidence that the
intended reuse is happening.

## Why this wasn't pursued further

Reaching the actual bottleneck would need either:

1. Special-casing known, trusted `Monad`/`HasIO` implementations (e.g.
   concrete `Prelude.IO`'s own `>>=`, which genuinely does invoke its
   continuation exactly once, in tail position) so `Reuse` (or a
   preceding pass) can treat that specific continuation as if it were a
   direct tail call -- narrow, somewhat unprincipled (only helps when
   the compiler happens to recognize the specific bind implementation
   in play), and unclear how often the concrete `io` is even known at
   compile time for library code written against `HasIO io =>` generically.
2. A more general "this closure is applied exactly once, in tail
   position, at the one place it's ever referenced" analysis that
   doesn't need to know monad semantics -- real interprocedural/escape
   analysis, comparable in scope to what the original dual-ABI escape
   analysis sketch (see `rc2/doc/dual-abi.md`'s own history) was, before
   that effort found a simpler path that avoided needing it.

Both are substantially bigger than anything shipped so far in this
area, for a benefit that's specific to one benchmark's one hot function
shaped this particular way. Not pursued; recorded here so a future
session with a similar-looking benchmark result doesn't have to
re-derive this chain of reasoning from scratch.

## Verification methodology (if reopening this)

1. `cd rc2 && source ../env.sh`
2. Write a minimal `HasIO io =>`-polymorphic repro using bang-notation
   on an effectful callback inside a case branch that reconstructs the
   scrutinee's own constructor (see the repro above).
3. `nix-shell -p idris2 gcc gmp pkg-config --run 'build/exec/idris2-rc2 --cg rc2 --directive dumprcexpr <file>.idr -o <out>'`
4. Read `build/exec/<out>.crexpr` (see `rc2/doc/reading-the-ir.md`) --
   look for `drop [...]` (unconditional) vs. `reuseOffer`/`reuse=` on the
   destructured scrutinee, and check whether the reconstruction is a
   `partial ... missing=N` call (bind continuation, unsafe to inline) or
   a fully-applied direct call.
5. For re-measuring against the real package: `rc2/tests/bench.sh
   --missing-containers --skip-build`, run both before/after any
   candidate source change *in the same session* (machine load varies
   enough between sessions that cross-session comparisons are
   unreliable -- re-time the baseline alongside any change, don't trust
   a figure recorded in an earlier document).
