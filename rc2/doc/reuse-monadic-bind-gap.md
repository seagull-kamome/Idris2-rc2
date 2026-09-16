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

## Confirmed workaround: monomorphizing to concrete `IO` sidesteps this entirely (2026-09-17)

Re-verified independently while scoping whether a narrow compiler fix was
feasible (it isn't -- see above; this session didn't change any code).
Compiled two versions of this doc's own repro shape side by side with
`--directive dumprcexpr` and every optimizing pass disabled (`noloop
noconstfold noinline nolateinline nospecclosure nomutualloop nodualabi
noconaltnative nodeadcode nodupmerge nosink`, to see the rawest possible
shape):

- **`replaceL2 : HasIO io => ... -> io (List KV)`** (this doc's own
  shape): reproduces exactly as described above. Worth noting one more
  detail the original investigation didn't spell out: the "coincidental"
  reuse from the Aside section fires on the `HasIO`/`Monad`/`Applicative`
  *dictionary* argument specifically (`v4` in this run) -- it's a
  single-constructor, multi-field record, so it shares `_builtin.CONS`'s
  physical shape with a list cons cell, same as the Aside's own
  dictionary-shaped example. The real list argument (`v8`) is dropped
  unconditionally at the point it's destructured, exactly as documented.
- **`replaceL2 : Nat -> String -> (Nat -> IO Bool) -> List KV -> IO (List KV)`**
  (identical body, `io` replaced by concrete `IO`, `HasIO io =>` dropped
  entirely): `>>=`/bang-notation compiles down to plain applies over an
  explicit threaded "world" value, entirely within `Main.replaceL2`'s own
  single definition -- no lambda-lifted continuation, no closure, no
  `partial ... missing=N`. `reuseOffer`/`reuse=` fires correctly on the
  real list cell at all three reconstruction sites (`con ... reuse=v7`
  in every branch). The gap this document describes simply does not
  exist for concretely-`IO` code, because Idris2's own `IO` compiles via
  direct world-token threading rather than interface-dictionary-based
  `>>=` dispatch.

### Concrete-`IO` dump (no gap)

`Main.replaceL2 (fun args=["v4:Boxed"(k), "v5:Boxed"(v), "v6:Boxed"(found),
"v7:Boxed"(xs), "v8:Boxed"(world)])`, `_builtin.CONS` branch (the `No`
alt, the recursive/reconstructing one):

```
_builtin.CONS [cons] tag=Just 1 args=[v10, v11] ->
  reuseOffer v7 dupOnShared=[v10, v11]
  let v12 : Boxed =
    let v13 : Boxed =
      dup v10
      call Main.key [v10]
    dup v4
    call Decidable.Equality.decEq [v4, v13]
  case v12 of
    Prelude.Types.Yes [datacon] tag=Just 0 args=[v14] ->
      drop [v12]
      let v15 : Boxed =
        let v16 : Boxed =
          dup v4
          apply v6 v4
        apply v16 v8
      case v15 of
        1 ->
          drop [v10, v15]
          let v17 : Boxed =
            con _builtin.CONS [cons] tag=Just 1 [v4, v5] reuse=v7
          con _builtin.CONS [cons] tag=Just 1 [v17, v11]
        0 ->
          drop [v4, v5, v15]
          con _builtin.CONS [cons] tag=Just 1 [v10, v11] reuse=v7
    Prelude.Types.No [datacon] tag=Just 1 args=[v18] ->
      drop [v12]
      let v19 : Boxed =
        call Main.replaceL2 [v4, v5, v6, v11, v8]
      con _builtin.CONS [cons] tag=Just 1 [v10, v19] reuse=v7
```

`case !(found k) of ...` became `apply (apply v6 v4) v8` (`v8`, the world
token, threaded as a plain extra argument) with the `True`/`False` split
as an ordinary `case v15 of 1 -> ... 0 -> ...` -- all inline in this one
function, one `reuseOffer v7` at the top covering every branch below it,
including the tail-recursive one.

### `HasIO io =>` dump (the gap)

Same source shape, `io` left abstract. `Main.replaceL2 (fun
args=["v4:Boxed"(dict), "v5:Boxed"(k), "v6:Boxed"(v), "v7:Boxed"(found),
"v8:Boxed"(xs)])` -- note `v8`, not `v4`, is the actual list argument
here (the `HasIO`/`Monad`/`Applicative` dictionary comes first):

```
case v8 of
  ...
  _builtin.CONS [cons] tag=Just 1 args=[v20, v21] ->
    dup v20
    dup v21
    drop [v8]                                  -- <- real list cell: unconditional drop, no reuseOffer
    let v22 : Boxed = ... call Decidable.Equality.decEq [v5, v23]
    case v22 of
      Prelude.Types.Yes [datacon] tag=Just 0 args=[v24] ->
        drop [v22]
        case v4 of
          _builtin.CONS [cons] tag=Just 1 args=[v25, v26] ->    -- dict, CONS-shaped
            ...
            let v30 : Boxed = ...                               -- Monad's own >>= method, applied
              let v33 : Boxed = dup v5; apply v7 v5              -- `found k`
              apply v31 v33
            let v34 : Boxed =
              partial Main.{replaceL2:0} missing=1 [v20, v21, v4, v5, v6]   -- continuation closure
            apply v30 v34                                        -- >>= invokes it -- opaque to Reuse
      Prelude.Types.No [datacon] tag=Just 1 args=[v35] -> ...    -- same shape, {replaceL2:1}

def Main.{replaceL2:0}  (fun args=["v59:Boxed"(x), "v60:Boxed"(xs'), "v61:Boxed"(dict),
                                    "v62:Boxed"(k), "v63:Boxed"(v), "v64:Boxed"(foundResult)])
  case v64 of
    1 ->
      drop [v59, v64]
      case v61 of                                    -- v61 is the CAPTURED DICT (v4), not the list
        _builtin.CONS [cons] tag=Just 1 args=[v65, v66] ->
          reuseOffer v61 dupOnShared=[v65] dropOnUnique=[v66]   -- "reuse" fires -- on the dictionary
          ...
          let v74 : Boxed =
            let v75 : Boxed = con _builtin.CONS [cons] tag=Just 1 [v62, v63]  -- fresh alloc, no reuse=
            con _builtin.CONS [cons] tag=Just 1 [v75, v60]                    -- fresh alloc, no reuse=
          releaseReuse v61
          apply v73 v74
    0 ->
      drop [v62, v63, v64]
      case v61 of
        _builtin.CONS [cons] tag=Just 1 args=[v76, v77] ->
          reuseOffer v61 dupOnShared=[v76] dropOnUnique=[v77]
          ...
          let v85 : Boxed =
            con _builtin.CONS [cons] tag=Just 1 [v59, v60] reuse=v61   -- reuses the DICT cell, not v8
          apply v84 v85
```

The list cell (`v8`/its tail `v21`, threaded into the helper as `v60`)
is never the reuse target anywhere in this trace -- every `reuse=`/
`reuseOffer` in `{replaceL2:0}` is on `v61`, the captured dictionary
(`v4`), confirming the Aside section's "reused, but the wrong cell"
finding directly against a second, independently-constructed repro.

Practical implication: a `HasIO io =>`-generic hot-path function that is,
in practice, only ever instantiated at concrete `IO` (true for
`Data.Container.Internal.IOHashSet`'s own `replaceL2`/`runIOHashSet`) can
sidestep this entire gap today, with zero rc2 changes, by declaring the
hot function directly against `IO` instead of `HasIO io =>`. This is a
library-level source change (e.g. in `idris2-missing-containers`), not
something rc2 can or should paper over by treating "the caller happens to
always pass `IO`" as a compile-time guarantee for a signature that says
otherwise -- but it's a real, low-risk mitigation worth knowing about
before reaching for either of the two large compiler-side options above.

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
