# Constructor-reuse-in-place analysis (`Compiler.RC2.Reuse`)

Implementation notes for the IR-level reuse pass, written to let a future
session (or a future you) regain full context without re-deriving the
design or re-discovering the bugs that were already found and fixed here.
Corresponds to commit `92078f8` ("Elevate constructor-reuse-in-place
analysis to a dedicated IR pass"); the file-level module comment in
`Compiler/RC2/Reuse.idr` is the authoritative summary, this document is
the *why* and *what went wrong along the way* that doesn't fit there.

## The optimization itself

When a constructor value dies right where it's matched (its scrutinee's
refcount was about to hit zero) *and* the matching branch goes on to
build a fresh constructor of the exact same name, the dying value's
heap storage can be repurposed in place instead of `free()`d and
`malloc()`d again -- a runtime `idris2rc2_isUnique(x)` check (`refCount
== 1`) gates it, falling back to an ordinary drop when the value turns
out to be shared. This mirrors RefC's own optimization; RefC decides it
during C emission using a stateful, name-keyed map. rc2 originally did
the same (`Emit.idr`, a `ReuseMap : SortedMap Name String` threaded
through a `Ref EnvTracker`) despite `RCExp.idr`'s own module note
claiming Emit is "purely mechanical." This module fixes that
inconsistency by deciding reuse the same way `RC.idr`'s `annotate`
already decides ownership: as data baked directly onto the IR, computed
once by a dedicated pass, with Emit.idr left to just lower it.

## Pipeline position

```
Lifted (Compiler.LambdaLift)
  -> Compiler.RC2.Inline          (whole-program inlining, Lifted -> Lifted)
  -> Compiler.RC2.RC.normalize    (Phase 1: ANF-style, native type inference)
  -> Compiler.RC2.RC.annotate     (Phase 2: ownership -- RDup/RDrop/RFree)
  -> Compiler.RC2.Reuse.resolveReuse   (this pass)
  -> Compiler.RC2.ConAltNative    (native-shadow field caching)
  -> Compiler.RC2.MutualLoop      (mutual tail recursion -> one merged function)
  -> Compiler.RC2.Loop            (self-tail-call -> RLoop/RLoopContinue)
  -> Compiler.RC2.DualABI         (worker/wrapper synthesis, call-site rewrite)
  -> Compiler.RC2.Emit            (purely mechanical RCExp -> C)
```

Wired in at `Compiler.RC2.RC2`'s `applyReuse`, called from `toRCDefs`
right after `toRCDef` (which itself already does normalize+annotate).
Runs once per top-level definition (`MkRCFun`/`MkRCError`); reuse offers
never cross a function boundary (`MkRCCon`/`MkRCForeign` pass through
unchanged, they have no body to walk).

**Why *after* annotate, not folded into it**: the reuse decision needs
to read the *already-computed* RDrop lists annotate produces (to know
whether a scrutinee dies right here) rather than re-deriving
ownership/borrow information itself. Interleaving would mean redoing
work annotate already did. This was an explicit design choice made with
the user mid-session (see conversation history if you need the exact
reasoning trace); the alternative (folding into `annotate` directly)
was considered and rejected as more complex for no benefit.

## IR additions (`RCExp.idr`)

- `RCon`'s `reuseFrom : Maybe RCLocal` -- `Just sc` means this
  construction may reuse `sc`'s storage. Phase 1/2 always leave it
  `Nothing`; only this pass ever sets it.
- `MkRConAlt`'s `offersReuse : Maybe RCLocal` -- `Just sc` means this
  alt's own scrutinee `sc` dies here *and* the body builds another
  constructor of the same name somewhere, so its drop becomes a reuse
  check instead of unconditional. Also always `Nothing` out of Phase
  1/2.
- `RReleaseReuse : FC -> RCLocal -> RCExp -> RCExp` -- new node, only
  ever inserted by this pass. Releases a reuse offer that turned out
  *not* to be consumed on a given execution path (a sibling branch
  claimed it, or no matching RCon was reachable on this path at all).
  Lowers to `idris2rc2_dropReuseConstructor(loc)`, which is a no-op if
  `loc` is NULL (already resolved elsewhere) and a real release
  otherwise.

`freeLocalsR`/`countUsesR` don't count `reuseFrom`/`offersReuse` --
same reasoning as `ROp.postDrop`: the local they name is already
counted via its own real binding site, so counting it again would be
redundant, never additive.

## Deterministic reservation naming (the key simplification over the old design)

The old `ReuseMap : SortedMap Name String` was keyed by *constructor
name*, meaning the C variable holding a reservation had to be looked up
by name at the point a matching `RCon` was emitted, with all the
associated statefulness (threading, snapshot/restore at scope
boundaries, `intersectionMap`/`differenceMap` narrowing).

This pass sidesteps the lookup table entirely: the reservation
variable's name is a pure function of the *scrutinee's own local id*
(`Emit.idr`'s `reuseVarName sc = "reuse_" ++ varName sc`), computed
identically by the offering alt, by whichever `RCon` claims it, and by
any `RReleaseReuse` that releases it -- because `resolveReuse` already
resolved *which* `RCon` claims a given offer and encoded that pairing
directly as data (`RCon.reuseFrom = Just sc`), there's nothing left to
rediscover at emission time. This also means offers are no longer
restricted to "one live reservation per constructor name" the way the
old map implicitly was (two different scrutinees building the same
constructor name can each get their own independent reservation) --
noted as an intentional relaxation, believed safe (each reservation is
tied to its own `sc`, resolved independently), not something carried
over from the old design on purpose.

## Algorithm (`Reuse.idr`)

### `peelDrop` / `rewrapDrop`

Every `RConAlt`/`RConstAlt`/default body produced by `RC.idr`'s own
`branchBody` (Phase 2) is wrapped in *at most one* leading `RDrop`
holding a flat list of locals dead at that branch's entry -- never a
chain of several. `peelDrop` exploits that invariant to inspect/rewrite
the branch's own drop list without walking the whole body;
`Emit.idr`'s own `peelDrop` (yes, there are two functions of this name,
one per module, doing the identical thing for the identical reason --
not merged into RCExp.idr's shared analyses because neither needs
`Core` effects) relies on the *same* invariant still holding after this
pass runs, so any rewrite here must preserve it (it does: `rewrapDrop`
only ever produces zero or one `RDrop` node).

### `resolveAlt` -- per-alt eligibility

An alt is eligible when, in its own peeled drop list:

1. its own scrutinee `sc` is present (dies here), and
2. it isn't one of the erased shapes (NIL/NOTHING/ZERO/UNIT -- these
   are NULL checks with no real heap object, nothing to reuse), and
3. `usedConstructorsR` on the (peeled) body contains the alt's *own*
   matched constructor name somewhere.

If eligible: `sc` is pulled out of the flat drop list (its fate becomes
the offer, not an unconditional drop), `offersReuse` is set to `Just
sc`, and `tryConsume` walks the body to find-and-claim (or release) the
offer. Ineligible alts (including the default branch, which has no
known scrutinee shape at all) are left with `offersReuse = Nothing` and
their drop list untouched.

### `tryConsume` / `tryClaim` -- finding a consumer

`tryClaim` recognizes a (possibly `RDup`-wrapped, since `annotate`'s
`wrapDups` can wrap a chain of `RDup`s around a freshly built `RCon`) an
unclaimed `RCon` of the target name at a single position -- it's a
one-shot check, not a search.

`tryConsume` is the actual search: it walks sequencing nodes (`RLet`,
`RDup`, `RDrop`, `RFree`) forward, trying `tryClaim` at each value
position (an `RLet`'s own `value`, since that's evaluated before
`body` and might itself be the construction), and on reaching a
genuine terminal (`RV`, `RAppName`, `RApp`, `RUnderApp`, `ROp`,
`RExtPrim`, `RPrimVal`, `RErased`, `RCrash`, or a bare tail-position
`RCon`) either claims it or wraps it in `RReleaseReuse` -- a function
call is *always* a dead end here (this is a purely local,
intraprocedural analysis; whatever the callee does is invisible).

When the search passes through a **nested** `RConCase`/`RConstCase`/
`RCmpCase`, it doesn't just look for the target inside -- it
recursively resolves *every* alt/branch of that nested case
independently (each could be the one actually taken at runtime), so a
nested case's own resolution never reports "still searching" back to
its caller: every one of its branches ends up either consuming the
offer or releasing it. This is what makes `tryConsume` a *total*
resolution, not a partial search that the caller has to handle
leftover cases for.

### Ordering: bottom-up, not top-down

`resolveReuse` recurses into a body *before* deciding the enclosing
alt's own eligibility. This means by the time an outer alt's own
`tryConsume` search runs, every nested opportunity has already claimed
whatever it was going to claim -- an outer search can only ever find
`RCon` nodes nested processing left unclaimed, never race with or
double-claim one out from under an inner offer. This ordering choice
was deliberate and is why there's no need for any cross-alt
coordination beyond "process children first."

## Emission (`Emit.idr`)

- `emitReuseOffer sc conArgs shouldDrop`: emits the
  `idris2rc2_isUnique(sc)` check, reclaiming `sc`'s storage into
  `reuse_<sc>` on the true branch, or (false branch) dup'ing whichever
  of `conArgs` survive (aren't in `shouldDrop`) before an ordinary drop
  of `sc`.
- `RCon`'s `reuseFrom = Just sc` lowers to referencing `reuse_<sc>`
  directly (guarded by `if (!reuse_<sc>) { reuse_<sc> = newConstructor(...); }`
  so a failed reservation still allocates normally).
- `RReleaseReuse` lowers to `idris2rc2_dropReuseConstructor(reuse_<sc>)`.

### The double-free bug found while wiring this up

`branchBody` (the shared lowering for `RConCase`/`RConstCase` alts and
defaults) originally special-cased the "dup surviving destructured
fields, then drop the parent without also flat-dropping them
individually" protocol as something that only applied when
`offersReuse` was set -- i.e. only on the actual reuse-offering path.
This is wrong: it's required on **every** matched-constructor branch
whose scrutinee dies there, independent of whether reuse fires at all,
because an ordinary `idris2rc2_drop` on the parent *recursively* drops
all of its fields -- a field that's still needed later in the branch
(and was only ever aliased, never independently ref-counted, via
`sc->args[k]`) needs a dup *before* that recursive teardown regardless
of whether the parent's storage happens to get reused afterward or
just freed normally.

The bug surfaced as a real `free(): unaligned chunk detected` crash in
the `wasm32cmp001`/`integers` refc-suite tests (comparison operators
route through `Prelude.EqOrd` instance methods that pattern-match a
constructor and then keep using one of its fields). Root-caused by
reading `git show <pre-refactor commit>:.../Emit.idr` to recover the
*original* `addReuseConstructor`'s exact behavior (its `else` branch --
the "not actually offering reuse" case -- still unconditionally did
`dupVars (conArgs \\ shouldDrop)` before returning `shouldDrop \\
conArgs` for the caller's flat drop) and restoring that as
`branchBody`'s unconditional behavior, with the reuse-specific
uniqueness check layered on top only for the `sc` itself, only when
`offersReuse` is set. See `branchBody`'s own doc comment in `Emit.idr`
for the final, correct version. Verified via the full refc-suite (all
19 tests), all 7 `tests/*.idr` smoke tests byte-identical to real RefC,
and all 3 benchmarks, with `idris2rc2_isUnique`/
`idris2rc2_dropReuseConstructor` both confirmed firing across several
refc-suite tests (not a silently-dead pass).

## Known, deliberately-unfixed edge case

`idris2rc2_dropReuseConstructor` (the release path) does **not**
recursively drop the released constructor's own fields, unlike an
ordinary `idris2rc2_drop`'s teardown. This is a pre-existing property
of the runtime (`support/rc2/runtime.c`), not something introduced by
this pass -- confirmed by reading its implementation before this work
started. It means: if a reservation is claimed (`isUnique` succeeded)
but then never actually consumed by any `RCon` on the specific
execution path taken (e.g. a sibling nested branch runs instead, and
`tryConsume` inserted an `RReleaseReuse` for this path), the *fields*
of the now-repurposed-then-abandoned storage are not cleaned up by the
release call itself. This is a latent gap, not verified to be
unreachable, and was explicitly **not** fixed as part of this work --
scope was "faithfully preserve existing behavior while moving the
*decision* to IR level," not "fix latent runtime issues discovered
along the way." Worth revisiting if it's ever confirmed to fire in
practice.

## Files

- `rc2/src/Compiler/RC2/Reuse.idr` -- the pass itself (new module).
- `rc2/src/Compiler/RC2/RCExp.idr` -- `RCon.reuseFrom`,
  `MkRConAlt.offersReuse`, `RReleaseReuse`.
- `rc2/src/Compiler/RC2/RC.idr` -- Phase 1/2 always leave the new
  fields `Nothing`/`[]` as appropriate; no ownership-logic changes.
- `rc2/src/Compiler/RC2/Emit.idr` -- `reuseVarName`, `emitReuseOffer`,
  `branchBody` (the RUnderApp/RAppName closure-building special case
  added later, commit `22ade30`, is unrelated to reuse and lives in the
  same function only incidentally).
- `rc2/src/Compiler/RC2/RC2.idr` -- `applyReuse`, pipeline wiring.

## Verification methodology (for repeating after future changes)

1. Build + regression baseline: see `CLAUDE.md`'s "Build & test" section
   (`idris2 --build rc2.ipkg`, then `tests/refc-suite/run.sh`, expect
   19/19). Pay particular attention to `reuse`/`refc001`-`refc003`
   (exercise this optimization directly) and anything touching
   `Prelude.EqOrd`/pattern-heavy code (comparisons, `basicpatternmatch`)
   since that's where the double-free above actually surfaced.
2. Grep generated `.c` under `tests/refc-suite/*/build/exec/` for
   `idris2rc2_isUnique` and `idris2rc2_dropReuseConstructor` to confirm
   the optimization is actually firing (both consume and release paths)
   rather than silently never triggering.
3. Full `tests/*.idr` smoke-test suite (`Test1Basics`..`Test7CastMatrix`)
   diffed against real `idris2 --cg refc` output (or the saved
   `.expected` file for `Test7CastMatrix`, whose RefC comparison is
   blocked by unrelated nixpkgs RefC-runtime bugs -- see its own module
   comment).
