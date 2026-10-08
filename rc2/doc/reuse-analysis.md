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
  -> Compiler.RC2.InlineCExp      (whole-program inlining, before lambda lifting)
  -> Compiler.RC2.RC.normalize    (Phase 1: ANF-style, native type inference)
  -> Compiler.RC2.RC.annotate     (Phase 2: ownership -- RDup/RDrop/RFree)
  -> Compiler.RC2.Reuse.resolveReuse   (this pass)
  -> Compiler.RC2.ConAltNative    (native-shadow field caching)
  -> Compiler.RC2.MutualLoop      (mutual tail recursion -> one merged function)
  -> Compiler.RC2.Loop            (self-tail-call -> RLoop/RLoopContinue)
  -> Compiler.RC2.Sink            (branch-local sinking, see doc/branch-sinking.md)
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
- `RReuseOffer : FC -> (sc : RCLocal) -> (dupOnShared : List RCLocal) -> RCExp -> RCExp`
  -- new node, replacing an earlier `MkRConAlt.offersReuse : Maybe
  RCLocal` flag design. A runtime uniqueness check on `sc`: if unique,
  its storage is reserved for a later `RCon` of the same shape to claim
  (`reuseFrom = Just sc`); otherwise every `dupOnShared` entry
  (destructured straight out of `sc`, plain pointer aliasing) is dup'd
  before `sc` drops normally. Either way execution continues into
  `body` -- a setup step with two ways of getting there, not a
  two-armed branch like `RCmpCase`/`RConCase`. Only ever inserted by
  this pass's `resolveAlt`, wrapping (a prefix of) whatever an eligible
  `RConAlt`'s own body already was -- see "Algorithm" below for the
  full eligibility protocol.
- `RReleaseReuse : FC -> RCLocal -> RCExp -> RCExp` -- new node, only
  ever inserted by this pass. Releases a reuse offer that turned out
  *not* to be consumed on a given execution path (a sibling branch
  claimed it, or no matching RCon was reachable on this path at all).
  Lowers to `idris2rc2_releaseReuse(loc)` (formerly `idris2rc2_dropReuseConstructor`), which is a no-op if
  `loc` is NULL (already resolved elsewhere) and a real release
  otherwise. Exactly one `RCon` reachable from an `RReuseOffer`'s own
  `body` ends up claiming it; every other path gets an
  `RReleaseReuse sc` instead, so a reservation is never simply lost.

`freeLocalsR`/`countUsesR` don't count `RCon`'s own `reuseFrom` -- same
reasoning as `ROp.postDrop`: the local it names is already counted via
its own real binding site (the enclosing `RReuseOffer`'s `sc`), so
adding it again would only be redundant, never additive.
`RReuseOffer`'s own `sc`/`dupOnShared`, by contrast, *are* counted --
they're genuine uses of those locals, not a derived echo of another
field.

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
the offer, not an unconditional drop), the alt's body is wrapped in an
`RReuseOffer sc ...`, and `tryConsume` walks the body to find-and-claim
(or release) the offer. Ineligible alts (including the default branch,
which has no known scrutinee shape at all) get no `RReuseOffer` and
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
- `RReleaseReuse` lowers to `idris2rc2_releaseReuse(reuse_<sc>)` (originally `idris2rc2_dropReuseConstructor`; see the addendum at the end).

### The double-free bug found while wiring this up

`branchBody` (the shared lowering for `RConCase`/`RConstCase` alts and
defaults) originally special-cased the "dup surviving destructured
fields, then drop the parent without also flat-dropping them
individually" protocol as something that only applied when
an `RReuseOffer` was present -- i.e. only on the actual reuse-offering path.
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
an `RReuseOffer` is present. See `branchBody`'s own doc comment in `Emit.idr`
for the final, correct version. Verified via the full refc-suite (all
19 tests), all 7 `tests/*.idr` smoke tests byte-identical to real RefC,
and all 3 benchmarks, with `idris2rc2_isUnique`/
`idris2rc2_dropReuseConstructor` both confirmed firing across several
refc-suite tests (not a silently-dead pass).

## Known edge case -- now confirmed resolved by the `dropOnUnique` addendum below

`idris2rc2_dropReuseConstructor` (the release path) does **not**
recursively drop the released constructor's own fields, unlike an
ordinary `idris2rc2_drop`'s teardown. This is a pre-existing property
of the runtime (`support/rc2/runtime.c`), not something introduced by
this pass. At the time this section was originally written, it was
flagged as a latent, unverified gap: if a reservation is claimed
(`isUnique` succeeded) but then never actually consumed by any `RCon`
on the specific execution path taken, the *fields* of the
now-repurposed-then-abandoned storage looked like they might not be
cleaned up by the release call itself.

**Re-investigated later (two rounds) and confirmed unreachable, not
just unconfirmed.** A first, analysis-only pass concluded this WAS
reachable; actually compiling a repro and checking it under valgrind
proved that wrong -- `RC.idr`'s own ordinary per-branch dead-variable
cleanup already drops any field genuinely dead in an abandoning branch
before `idris2rc2_dropReuseConstructor` is ever reached, so adding a
recursive drop there would double-drop, not fix anything. A second
round found the actual structural reason: the `dropOnUnique` addendum
below partitions every one of a destructured constructor's own fields
into exactly two disjoint sets (`dupOnShared`/`dropOnUnique`, related
by plain set subtraction) with no third bucket a field could fall into
unnoticed, and both sets are fully discharged (dup'd or dropped)
*before* a reservation is ever claimed or released. By the time
`idris2rc2_dropReuseConstructor` runs, every field's ownership is
already resolved -- there is nothing left for it to recursively drop.
`idris2rc2_dropReuseConstructor` needs no change.

## Addendum: `dropOnUnique` -- a destructured field leaking on the reuse-in-place (unique) path

Found and fixed after the above was written. A field destructured out of
`sc` but never referenced anywhere in the branch body (not read, not
passed on, not part of `dupOnShared` because nothing downstream needs it
dup'd) had no owner dropping it on the reuse-in-place path:
`emitReuseOffer`'s **true** (unique) branch reclaims `sc`'s storage
directly into `reuse_<sc>` without ever calling an ordinary
`idris2rc2_drop(sc)` -- unlike the **false** (not-unique) branch, which
does drop `sc` (after dup'ing whichever of `conArgs` survive), and whose
recursive teardown was exactly what such an unreferenced field's drop
was implicitly relying on. On the unique path nothing plays that role,
so the field's own refcount was never decremented -- a real leak, not
merely a missed dup.

Fixed by adding a new `dropOnUnique : List RCLocal` field directly on
`RReuseOffer` (`RCExp.idr`), computed in `Reuse.idr`'s `resolveAlt`
alongside `dupOnShared` (the same peeled-drop-list analysis that already
identifies `sc` and its destructured fields, just naming the
complementary set: fields that die on the unique path specifically,
because they're absent from the body's own later uses). Discharged only
in `Emit/Util.idr`'s `emitReuseOffer`'s unique branch -- each
`dropOnUnique` entry gets an ordinary drop there, right before
`reuse_<sc>` is claimed -- deliberately left untouched in the
not-unique branch, since that branch's existing unconditional
`idris2rc2_drop(sc)` already recursively drops every field, and dropping
the same field twice there would be a double-free, not a fix.

Regression test: `rc2/tests/Test36ReuseOfferUniqueLeak.idr` -- a
minimal, socket-free repro (an outer `do` with 2+ binds, plus a nested
`do` in an `if`'s else-branch with its own bind), engineered to force
exactly this reuse-in-place shape. Confirmed via `--directive
dumprcexpr` IR tracing and by inspecting the generated C, not just by
observing the leak disappear under `valgrind`.

## Addendum: a dead offer releases up front, not once per leaf

`resolveAlt`'s own eligibility pre-filter is `contains name
(usedConstructorsR inner)` -- "a same-named constructor appears
*somewhere* below". `tryClaim` reaches far fewer positions than that,
so the filter is optimistic: measured over a whole idris2-lsp build,
**3,228 of 19,011 offered scrutinees (17%) are never claimed by any
`con ... reuse=`**.

`tryConsume` now reports whether it claimed anywhere. For a dead
offer, what changes is *where the release goes*, not whether the offer
exists:

- **The branch stays.** Collapsing a dead offer to its own "shared"
  path unconditionally was tried and **measured to be a
  pessimization**: `idris2rc2_dropReuseConstructor` frees the shell
  *without* recursing into the fields, so the unique path genuinely
  avoids dup/drop-ing every surviving field. Removing it pushed
  idris2-lsp's own `dup` count 95,020 -> 105,619 and `drop`
  84,111 -> 92,077, to save one branch. Don't re-try this.
- **The release moves up.** `tryConsume` scatters an `RReleaseReuse`
  onto *every* leaf path that fails to claim -- for a dead offer that
  is every path there is. One `RReleaseReuse` wrapped directly around
  the body does the same job: the shell goes back to the allocator at
  once instead of at whichever leaf happens to run, and
  `reuseVarName sc`'s own C local stops spanning the whole body.

Measured over a whole idris2-lsp build: `releaseReuse` nodes
**33,117 -> 10,270** (-22,847, a 69% cut), each one an
`idris2rc2_dropReuseConstructor` call site in the generated C.
`reuseOffer` (29,452) and `reuse=` (21,829) are both unchanged -- no
reuse opportunity is given up, only the bookkeeping for offers that
never had one.

## Nested let values (`tryConsume` descends into an `RLet` value)

Motivation. An audit of the final idris2-lsp IR found 5,921 of 13,031
reuse offers dead (no path claims the shell; the offer is followed by
`releaseReuse`). 4,384 of them had a same-name constructor that exists
only inside the *value* of a `let` -- typically
`let r = case x of ... Cons a b => ...  in <use r>` after destructuring
a `Cons`/`Right`/`Left` -- which `tryClaim` (one position, no descent)
could never reach. The body search ran past the `let` and found nothing.

Rule. In `tryConsume`'s `RLet` case the order is:

1. `tryClaim` on the value (unchanged);
2. `tryConsume` on the body (unchanged); if it claims anywhere, that is
   the result, exactly as before;
3. only if the body claims nowhere (and `noreusenested` is not given):
   run the *full* `tryConsume` on the value. If that claims on some
   path, the result is `RLet var rep value' body` with the original,
   untouched body. The all-release rewrite of the body found in step 2
   is discarded.

Because step 3 runs only when steps 1-2 found nothing, no claim that
exists today moves: the real-reuse count can only go up, and with the
switch the output is byte-identical to the previous behaviour (checked
on the idris2-lsp dump: identical apart from the directive header).

Safety argument (the four questions settled before the change):

1. *Exactly once on every path.* `tryConsume` is total: every leaf of
   the value tree (through nested `case`, `let`, `dup`/`drop`/`free`) is
   either `con ... reuse= sc` or wrapped in `releaseReuse sc`, and a
   leaf ends a path, so at most one claim per path. `reuse_<sc>` is NOT
   cleared by a claim (`emitRC (RCon ..)` only reads it), so a release
   after a claim on the same path would free a live cell; this is why
   step 3 leaves the body alone: once the value has been resolved, no
   node after it may mention `sc`. Two branches that both contain a
   `con` each claim in their own branch only (a path takes one branch).
   The leak lint's reuse-token join check ("reuse token live on one side
   only") and "reuse without offer" / "releaseReuse without offer"
   checks verify this on the whole idris2-lsp IR (0 anomalies).
2. *Retention.* The shell is held while the value is evaluated, with its
   fields already moved out; a release happens at the first
   non-claiming leaf, i.e. *earlier* than the old end-of-body release.
   The cost is at most one pointer-sized C local per active frame plus
   the (not yet freed) cell, which the program would otherwise have freed
   and re-allocated; the cell count never exceeds the number of cells the
   unoptimised program had live. A frame that holds a shell across a
   non-tail call is already the status quo for `let x = call in Con ..`
   in the body, so no call-free / size bound is imposed. Measured on
   a 1,000,000-deep recursion inside a let value: peak RSS 112 MB -> 128
   MB (+14%, one saved pointer per frame), no failure.
3. *Interaction with other passes and constructs.* `RDelay` carries only
   a thunk name and captures (the thunk body is a separate lifted
   definition) and `RMemoize` only wraps a CAF's whole body, so neither
   can occur inside a descended value; any other node falls into the
   terminal case and gets a release. A let value is never in tail
   position, so `Loop`/`MutualLoop` (which run later) never see a
   continue inside one, and the shell never survives an iteration
   (every leaf resolves). `Sink` only moves a bare `op`/`con`/call let,
   never a case-valued one. `DualABI`'s tail-`con ... reuse=` to retpack
   rewrite is untouched: a claim in a let value is not a tail. The later
   passes already handle `reuse=` and `releaseReuse` inside case
   branches within let values (inner offers produce that today).
4. *Threads.* Unchanged: the shell is solely owned after `isUnique`.

Switch: `--directive noreusenested` (see `directives.md`).

Measured on idris2-lsp (17,549 definitions), with vs. without the switch:

| | `noreusenested` | default |
| --- | ---: | ---: |
| `reuseOffer` | 13,031 | 13,030 |
| `con ... reuse=` | 7,811 | 12,189 |
| `releaseReuse` | 9,250 | 10,103 |
| dead offers (offer directly followed by its release) | 5,474 | 1,757 |
| dupOnShared / dropOnUnique entries | 31,387 / 1,517 | 31,385 / 1,517 |
| `dup` / `drop` lines | 74,638 / 64,804 | 74,639 / 64,803 |
| IR lines | 658,449 | 659,301 |
| rcexpr-lint anomalies | 0 | 0 |

Compile time is within noise (227 s vs. 222 s, two builds in parallel).
Runtime on a micro-benchmark whose hot loop builds the result inside a
let-bound three-way `case` (list of 100, 200,000 rounds): 1.20 s -> 0.48
s (-60%), single-threaded, 5 alternating runs.

Not covered: a `con` that only exists after the claim position of a
*partly* claiming body (step 2 wins over step 3, even if the value would
claim on more paths); the 274 offers whose same-name constructors were all
claimed by inner offers (bottom-up order); tail `con ... reuse=` that
`DualABI` turns into a retpack after releasing the shell (class A).

## Files

- `rc2/src/Compiler/RC2/Reuse.idr` -- the pass itself (new module).
- `rc2/src/Compiler/RC2/RCExp.idr` -- `RCon.reuseFrom`,
  `RReleaseReuse`, `RReuseOffer.dropOnUnique`
  (see the `dropOnUnique` addendum above).
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
3. Full `tests/*.idr` smoke-test suite (`Test111Basics/Basics.idr`..`Test7CastMatrix`)
   diffed against real `idris2 --cg refc` output (or the saved
   `.expected` file for `Test7CastMatrix`, whose RefC comparison is
   blocked by unrelated nixpkgs RefC-runtime bugs -- see its own module
   comment).

## Addendum: `releaseReuse` frees the shell directly

`RReleaseReuse` used to lower to `idris2rc2_dropReuseConstructor`, which
went through `idris2rc2_rc_release` (an atomic `fetch_sub` once the
program is multi-threaded) before the `free`. It now lowers to the
`static inline idris2rc2_releaseReuse` in `idris2rc2_rt.h`, which is just
`free(c)` (`free(NULL)` is a defined no-op, so the common shared path
pays no call and no branch). The old out-of-line
`idris2rc2_dropReuseConstructor` symbol was removed (the compiler is under
development; generated C is not kept binary-compatible).

Why this is sound:

- A non-NULL `reuse_<sc>` is only ever assigned on the success branch
  of `emitReuseOffer`, i.e. `idris2rc2_isUnique(sc)` held: refcount
  exactly 1. An immortal/static value (`IDRIS2RC2_REFCOUNT_MAX`) and an
  unboxed value are never unique, so they can never become a shell.
- In threaded mode `isUnique` reads the count with an acquire load,
  pairing with every other thread's release-decrement. Seeing 1 means
  every other owner has dropped its reference and nothing can dup the
  value again, so this thread owns it exclusively; no other thread
  can reach the cell, and no RMW is needed to publish its death.
- The shell's fields are deliberately not touched: the offer already
  moved them out (`dupOnShared`/`dropOnUnique` handle the survivors),
  so no recursive teardown is wanted -- the old path also never
  recursed.
- `idris2rc2_alloc` is plain `malloc` today, matching `free`. A future
  small-object allocator needs to give this site its matching release.
- With `-DIDRIS2RC2_DEBUG` the helper additionally VERIFYs `rc == 1`.

Measured (200000 x 100-element list loop whose cons alt fires
offer+releaseReuse on every element, 5 alternating runs): single-threaded
~802 ms -> ~778 ms (-3%); with `idris2rc2_enableMultiThreading` called
first ~905 ms -> ~774 ms (-14%).
