# Tail-call loop conversion (`Compiler.RC2.Loop`, `Compiler.RC2.MutualLoop`)

Implementation notes for rc2's tail-recursion-to-`goto` machinery --
self-tail-calls, mutual tail recursion across two or more functions, and
the native-representation promotion layered on top of both. Written to
let a future session (or a future you) regain full context without
re-deriving the design or re-discovering the bugs already found and
fixed here. Companion to `doc/reuse-analysis.md` (the other
after-Phase-1+2 IR rewrite pass) and `doc/native-type-inference.md`
(the native/Boxed `Rep` machinery this document's own native-shadow
promotion builds directly on top of).

(This document absorbs what used to be three separate "(implemented)"
entries in `TODO.md` plus its own "Native-shadow eligibility stops at
bare top-level scalars" note -- moved here in full, since they describe
finished design/implementation, not an open gap. `TODO.md` keeps only a
short pointer.)

## The optimizations, and why each one exists

Idris2's own compiled IR represents *every* call uniformly: build a
closure, trampoline through it. For a recursive function, that means
every single iteration allocates a closure, fills in its argument
slots, and returns through a generic dispatch loop -- even though a
tail-recursive function's own "next iteration" is, semantically,
nothing more than "reassign my parameters and jump back to the top."

Two layered optimizations attack this, in the order they were built:

1. **Tail-call -> `goto`** (this document's main subject): a
   self-recursive tail call, or a tail call within a cycle of two or
   more mutually tail-recursive functions, compiles to reassigning C
   parameter variables and a plain `goto` back to the function's own
   top -- no closure allocation, no trampoline dispatch, per iteration.
2. **Native-representation loop-carried parameters** (built directly on
   top of (1), see its own section below): a loop parameter that's
   read as a native-context numeric operand *anywhere* in the loop body
   gets unboxed exactly once, at loop entry, instead of being
   re-boxed into a fresh heap value at every `goto` only to be
   immediately re-unboxed at the top of the next iteration.

Both are pure code-shape/representation changes -- neither one makes a
new ownership decision of its own; both reuse exactly what
`Compiler.RC2.RC`'s `annotate` (Phase 2) already decided about the
original, pre-conversion call. That reuse is what keeps each of these
passes small: getting ownership *right* was already solved once,
upstream; the job here is purely "don't disturb it while changing the
call's shape."

## Pipeline position

```
Lifted (Compiler.LambdaLift)
  -> Compiler.RC2.RC.normalize      (Phase 1: ANF-style, native type inference)
  -> Compiler.RC2.RC.annotate       (Phase 2: ownership -- RDup/RDrop/RFree)
  -> Compiler.RC2.Reuse             (constructor-reuse-in-place)
  -> Compiler.RC2.MutualLoop        (mutual tail recursion -> one merged function)
  -> Compiler.RC2.Loop              (self-tail-call, incl. MutualLoop's own
                                      merged functions -> RLoop/RLoopContinue,
                                      plus native-shadow promotion)
  -> Compiler.RC2.Emit              (purely mechanical RCExp -> C)
```

`MutualLoop` runs *before* `Loop`, not after, and this ordering is the
crux of `MutualLoop`'s entire design (see its own section below): by
the time `Loop` ever sees a `MutualLoop`-merged function, every one of
its internal transitions (self- or cross-member alike) is already an
ordinary tail call to *itself* -- indistinguishable, from `Loop`'s point
of view, from a hand-written self-recursive function. `Loop` needed
zero special-casing to also convert `MutualLoop`'s own output; that's
not an accident, it's the specific property `MutualLoop` was designed
to produce.

## IR shape: `RLoop` / `RLoopContinue`

```idris
RLoop         : FC -> (loopParams : List (Int, Rep)) -> (initial : List RCLocal) -> RCExp -> RCExp
RLoopContinue : FC -> List RCLocal -> RCExp
```

`RLoop` wraps a whole tail-recursive loop: `loopParams` are this loop's
own carried locals, each with its **own** `Rep`, independent of
whatever representation the *enclosing function's* own top-level
parameters use (always Boxed, per the external calling convention);
`initial` supplies each one's starting value (same order, same length),
evaluated once, in the *enclosing* scope, before the loop itself ever
runs. `body` is then evaluated repeatedly -- an `RLoopContinue` reachable
from it in tail position supplies new values for the next iteration and
jumps back to the top; any other tail-position value exits the loop and
becomes the whole `RLoop` node's own result. Only ever produced by
`Compiler.RC2.Loop`; `RC.idr`'s own Phase 1/2 never construct either
node.

### Why this shape, and not something simpler

An earlier design iteration used a flat `isLoop : Bool` field on
`MkRCFun` plus a scattered `RSelfTailCall` node standing in for each
converted call -- i.e. no explicit "this is the loop" boundary at all,
just a flag on the function and markers at each jump-back site. That
design could only ever express "the whole function body is Boxed, and
some tail calls become `goto`s" -- it had no way to say "*this specific
loop parameter* has its own representation, distinct from the
function's own calling convention," because there was no IR-level
concept of "the loop" as a thing with its own identity separate from
the enclosing function.

Native-shadow promotion (next section) needs exactly that: a
loop-carried parameter's *native* representation only holds while
control stays inside the loop -- the function's own entry point (a call
from outside) and exit point (the loop's own final value) both still
need the ordinary Boxed value. Two designs were considered for
expressing this before `RLoop`/`RLoopContinue` was settled on:

1. **Unbox once at function entry, keep native throughout, rename the
   shadowed variable's id everywhere it's used.** Rejected: blindly
   substituting `RCLoc p -> RCLoc shadowId` across the whole function
   body, without also touching anything else, corrupts the *existing*
   ownership annotations `annotate` already computed for `p` (its own
   `postDrop` entries, standalone `RDrop`/`RDup` nodes -- all sized and
   placed for a value that gets read from multiple *Boxed*-context
   sites, an assumption the substitution alone doesn't fix) --
   and does so silently, producing code that type-checks and even often
   runs, but leaks or double-frees under the right input. (This turned
   out to be a real risk, not a hypothetical one -- see "Bugs found"
   below: even the *narrower*, properly-scoped version of this rewrite
   this document describes needed a dedicated ownership-stripping step
   to get right.)
2. **Make box/unbox explicit IR nodes, treated as ordinary
   operand-consuming/producing nodes like `ROp`, and let Phase 2's
   existing `annotate` machinery decide their ownership the same way it
   already decides everything else's.** This is architecturally
   appealing (zero new ownership logic anywhere) but requires this
   decision to be made *during* Phase 1, before `annotate` ever runs --
   and Phase 1 has no concept of "this is a loop" at all (loop
   detection is a structural property of tail positions, discovered by
   a *later*, dedicated pass, deliberately kept separate from ANF
   normalization). Doing this properly would mean folding loop
   detection into Phase 1 itself, a much larger restructuring than the
   rest of this work, and was set aside as out of scope for this
   iteration (see `TODO.md`'s "Dual calling convention" -- the general,
   any-call-boundary version of "let native representations cross a
   boundary" remains unimplemented for exactly this class of reason).

`RLoop`/`RLoopContinue`'s split resolves this without either cost:
"runs once" (`initial`, evaluated in the *enclosing* scope, still
talking about the original Boxed parameter) and "repeats" (`body`,
talking about the loop's own params, each with its own `Rep`) become
two structurally distinct positions in the IR itself. A late pass (this
one) can then make the promotion decision *after* `annotate` has
already run, and correctness reduces to two well-scoped, mechanical
steps -- a whole-tree rename plus a targeted ownership strip -- rather
than needing Phase 1 to know about loops at all. See "Native-shadow
promotion" below for exactly how those two steps work and why they're
sufficient.

## `Compiler.RC2.Loop`: self-tail-call conversion

### `mapTailAppNames` -- the shared tail-position walk

```idris
mapTailAppNames : (FC -> Name -> List RCLocal -> Maybe RCExp) -> RCExp -> (Bool, RCExp)
```

Rewrites every tail-position, non-lazy `RAppName fc Nothing n args` leaf
for which `f fc n args` returns `Just e'`, substituting `e'` in its
place. "Tail position" here is the *exact* structural set
`Compiler.RC2.Emit`'s own `TailPositionStatus` threading already visits
when lowering to C: `RLet`'s body; `RDup`/`RDrop`/`RFree`/
`RReleaseReuse`/`RReuseOffer`'s continuation; `RCmpCase`'s two
branches; `RConCase`/`RConstCase`'s alts and default. Operand positions
(`RCon`'s args, `ROp`'s operands, `RApp`'s own callee/arg, an
`RAppName`'s *own* arguments, ...) are never visited -- a call sitting
there isn't in tail position and must keep going through the ordinary
calling convention regardless of what `f` says.

Defined once, in `Loop.idr`, and shared by `Compiler.RC2.Loop` itself
(`f` matches only the enclosing function's own name) and
`Compiler.RC2.MutualLoop` (`f` matches any member of a whole
mutually-recursive group). This sharing isn't just deduplication --
it's a correctness requirement: if the two passes' own notions of "tail
position" ever disagreed, one pass could convert (or skip) a call the
other pass's `TailPositionStatus`-driven emission logic wouldn't agree
is a tail position, silently miscompiling.

### `applyLoop` -- the wrapping decision

```idris
applyLoop : Name -> RCDef -> RCDef
```

Given a definition's own name (threaded in explicitly by `RC2.idr`'s
`toRCDefs`, since `RC.idr` never carries a definition's own name
through Phase 1/2): runs `mapTailAppNames`, matching only calls that
target `self`, replacing each with `RLoopContinue fc args'`. If none
were found, the body passes through unchanged. If any were found, the
whole (rewritten) body gets wrapped in one `RLoop` -- and this is also
where native-shadow promotion happens, described next.

Scope, matching `mapTailAppNames`'s own restrictions: self-only (mutual
recursion is `MutualLoop`'s job, see below) and calls under a
`LazyReason` are excluded (conservative, not investigated further).
Ownership for the *wrapping* itself is completely unaffected -- `annotate`
already decided the right dup/move behaviour for the `RAppName`'s own
arguments before this pass ever runs, exactly as for a call to any
other function; converting the call's *shape* doesn't change what
should happen to its operands. Any `RDup`/`RDrop`/`RFree`/
`RReleaseReuse` wrapping the `RAppName` is left in place untouched;
only the terminal `RAppName` node itself is ever replaced.

### Native-shadow promotion

The second half of `applyLoop`: for each of the function's own
top-level parameters, decide whether it's worth promoting from `RBoxed`
to a fresh native shadow, and if so, rewrite the loop body accordingly.

**Eligibility (`nativeArgType`/`nativeArgTypes`)**: a parameter `p` is
eligible if the (already tail-call-rewritten) body reads it as a
native-context operand *consistently at one `PrimType`* -- specifically,
either as an operand of a fused `RCmpCase` (always native, regardless
of context), or as an operand of an `RLet`-bound `ROp` whose *own*
`Rep` is `RNative`/`RInlineNative` (a Boxed-*result* `ROp`'s own
operands are read Boxed too, via `emitRC`'s own `ROp` case -- they
don't count). These are the *only* two places `Compiler.RC2.Emit` ever
reads an operand via `rcVarToNativeC` rather than `rcVarToBoxedC`; the
eligibility scan is deliberately defined in exactly those terms so it
can never diverge from what Emit actually does. `nativeArgTypes` walks
the *whole* tree (not just tail positions -- an operand can appear
anywhere), collecting every such type into a `SortedSet`;
`nativeArgType` accepts only a *singleton* result (never read natively,
or read at conflicting types, both conservatively leave the parameter
`RBoxed`).

`opNativeUsesThrough` exists because an `RLet`'s own `value` isn't
always a bare `ROp` -- `annotate` (Phase 2) routinely wraps a
multiply-used operand's value in a leading `RDup` (or, less commonly,
`RDrop`/`RFree`/`RReleaseReuse`), the exact same shapes
`Emit.idr`'s own `emitNativeValue` already has to peel through before
it reaches the actual operation. **This was a real bug during
development, not a hypothetical**: an earlier version of the
eligibility scan pattern-matched `value` directly against `ROp`,
missing every parameter that happened to be `dup`'d before its own
arithmetic use (i.e. any parameter used more than once) -- see "Bugs
found" below for how this was diagnosed.

**Rewrite, once a set of eligible `(p, ty)` pairs is known**:

1. `assignShadowIds` mints one fresh id per eligible parameter,
   starting one past the highest id already used anywhere in the
   definition (`args` plus every `RLet`/`RConAlt`-bound id in the
   rewritten body, via `collectBoundIds`) -- a plain arithmetic
   maximum, not a `Core`-threaded counter, since this whole pass stays
   a pure function of one definition at a time (contrast with
   `MutualLoop`'s own `FreshId`, which genuinely needs to be threaded
   across the whole program).
2. `renameRCExp` (see below) substitutes every occurrence of each
   promoted parameter's original id with its fresh shadow id,
   uniformly across the whole body -- **every** occurrence, not just
   the ones inside native-context reads: a Boxed-context use (a
   constructor field, a call argument, the loop's own eventual return
   value) gets redirected too, and correctly so -- `rcVarToBoxedC` on
   a native-Rep'd local boxes it fresh on the spot, so a redirected
   Boxed-context read still produces the right *value*, just via a
   fresh allocation rather than sharing the original object's identity
   (a real but acceptable trade-off, not a correctness issue).
3. `stripOwnership` (see below) removes the now-stale ownership
   bookkeeping `annotate` had computed for the *original* parameter,
   keyed off the *shadow* ids (post-rename).
4. `loopParams` is built by mapping over the function's own `args`:
   an eligible parameter contributes `(shadowId, RNative ty)`; every
   other parameter contributes `(p, RBoxed)` unchanged (reusing its
   own id -- this is what lets `Compiler.RC2.Emit`'s `declareLoopParam`
   skip declaring it at all, see below). `initial` is *always*
   `map RCLoc args` regardless -- every loop param's starting value
   genuinely comes from reading the original, always-Boxed parameter;
   `Compiler.RC2.Emit`'s `declareLoopParam` does the (skipped, for an
   unchanged `RBoxed` param) unboxing conversion.

#### `renameRCExp` -- whole-tree substitution

```idris
public export
Renaming : Type
Renaming = SortedMap Int Int

export
renameRCExp : Renaming -> RCExp -> RCExp
```

A pure, meaning-preserving substitution over *every* `RCLocal`
occurrence and every bound id in a tree (unlike `mapTailAppNames`, not
restricted to tail positions -- a bound id or a read can appear
anywhere). Doesn't add or remove any `RDup`/`RDrop`/`RFree`/
`RReleaseReuse`/reuse-related node, just relabels what they (and every
read) refer to -- existing ownership nodes move to the new id along
with their target, unchanged in shape. `Renaming` is `public export`
specifically so a caller in a different module can write `SortedMap
Int Int` values directly against its exact underlying type without an
opaque-type unification failure (this bit -- `export` alone wasn't
enough -- see "Bugs found" below for the exact compile error it
produced).

Originally private to `Compiler.RC2.MutualLoop` (which needs it for its
own per-member id renaming, see below); moved here specifically so both
`MutualLoop` and this module's own native-shadow rewrite share one
definition instead of two hand-synchronized copies. `MutualLoop.idr`
already imports `Compiler.RC2.Loop` (for `mapTailAppNames`), so this
didn't introduce any new module dependency -- it just relocated
existing code along an edge that already existed.

`collectBoundIds : RCExp -> List Int` lives right beside it for the
same reason (`MutualLoop`'s own `buildGroup` needs "every locally-bound
id in a body" to know which internal ids need fresh names alongside a
member's own top-level parameters; this module's own `applyLoop` needs
it to pick a starting point for fresh shadow ids that can't collide
with anything already in scope).

#### `stripOwnership` -- removing a promoted parameter's stale bookkeeping

```idris
stripOwnership : SortedSet Int -> RCExp -> RCExp
```

Removes every `RDup`/`RDrop`/`RFree` target, and every `ROp`/
`RCmpCase` `postDrop` entry, naming one of `ids` (the *shadow* ids,
post-rename -- not the original parameter ids, since by the time this
runs every value-reading occurrence has already been redirected to the
shadow). A native value never needs reference-count bookkeeping at all
-- there's no refcount header on a raw C scalar to pass to
`idris2rc2_dup`/`idris2rc2_drop`/`idris2rc2_free` -- so whatever
`annotate` originally decided about the *original*, still-Boxed
parameter's own dup/drop lifetime (back when it was read from multiple
Boxed-context sites across the loop body) no longer applies and must be
removed outright, not merely left in place.

**Why this is safe**: precisely because every *other* occurrence of the
promoted parameter was already redirected to its shadow by the
accompanying `renameRCExp` call, run *before* this. There is no
surviving Boxed read anywhere in the tree that still needs the drop
being removed -- if there were, this step would be unsound; the ordering
(rename first, strip second, both keyed to the same shadow-id set) is
what makes the two steps compose into a correct whole.

**Why `RCon`'s own field arguments, an `RConCase`/`RConstCase`
scrutinee, and `RReuseOffer`'s own `sc`/`dupOnShared` are deliberately
*not* touched** (`renameRCExp` still substitutes the id in them, same
as everywhere else -- only their *ownership* bookkeeping is a distinct
concern from this function's job): a parameter eligible for native
shadowing (an `ROp`/`RCmpCase` operand -- i.e. a numeric type) and a
parameter pattern-matched or reuse-checked as a constructor are
mutually exclusive *at the Idris type level* -- a single Idris-level
value can't simultaneously be a native-eligible scalar and an ADT
subject to constructor dispatch -- so a shadowed id is never one of
those to begin with. And a shadowed id stored into a constructor field
just gets boxed fresh on the spot by `rcVarToBoxedC`, correctly, with
no bookkeeping node of its own to strip.

`RConstCase`'s scrutinee deserves a second look, though, because it
*can* legitimately be a native-eligible numeric type (unlike
`RConCase`, which only ever matches a constructor/ADT shape) --
pattern-matching a loop counter against a literal (`case n of 0 =>
...`) is exactly this shape, and exactly the case `BenchLoop.idr`'s own
`sumTo` hits. `stripOwnership` correctly leaves this alone (there's no
ownership node attached to a scrutinee position itself to strip), but
this is also precisely the gap that produced a real emission-side bug
-- see "Bugs found" below.

## `Compiler.RC2.MutualLoop`: mutual tail recursion

### The problem `RLoop`/`RLoopContinue` alone don't solve

`Compiler.RC2.Loop` only ever recognizes a tail call targeting the
*enclosing function itself*. Two (or more) functions that tail-call
each other in a cycle -- the textbook example being `isEven`/`isOdd` --
have no such self-call anywhere; each one's own tail call targets a
*different* function. Extending `RLoop`/`RLoopContinue` to somehow span
multiple named functions was considered too large a change to the core
IR shape for what's fundamentally a code-generation-time
transformation, not a new runtime concept.

### The design: merge the cycle into one function

Rather than inventing new IR, this pass synthesises, for each group of
`>= 2` functions that mutually tail-call each other, a single new
merged function whose body is a plain `RConstCase` switching on a small
integer tag -- one alt per original group member -- and rewrites
*every* tail call within the group (self- or cross-member alike) into
an ordinary tail call to that merged function itself, carrying the
target's tag and (padded) arguments. From that merged function's own
point of view, every one of those is now just a plain self-tail-call --
exactly the shape `Compiler.RC2.Loop` (which runs immediately
afterward) already knows how to turn into a `goto`. This is the whole
reason `MutualLoop` runs *before* `Loop`, not after, or as some
integrated part of it: `Loop` needs **zero** new logic to also handle
merged mutual recursion, because by the time it sees the merged
function, the problem it's solving is identical to the one it already
solves.

Each original member's own top-level name keeps working as a normal,
independently-callable function (for external callers, and for any
*non*-tail use -- e.g. being passed around as a closure, which
`Test10MutualLoop.idr` specifically exercises) -- it becomes a thin
wrapper that just calls the merged function once with its own tag and
arguments and returns whatever comes back.

Because all of rc2's own calling convention is uniformly `Value*`, the
merged function's parameters are just `tag, slot_0 .. slot_k` (`k` =
the largest arity among the group's members) -- every ordinary
`RCLocal`, nothing backend-specific. Members with a smaller arity
simply never reference their own unused trailing slots, and every
caller (wrapper or in-group transition) always pads them with `RCNull`.

### Cycle detection: Tarjan's SCC, not just direct pairs

`tailCallTargets` (a read-only sibling of `Loop.idr`'s own
`mapTailAppNames`, over the *same* structural notion of tail position
-- same correctness requirement as discussed above, the two must never
disagree) collects, for a single definition, the set of names any tail
call targets. `buildGraph` turns this into a `Graph = SortedMap Name
(SortedSet Name)` restricted to edges between definitions the pass
itself is considering (i.e. `MkRCFun`s only). `tarjanSCCs` is a
straightforward iterative-with-explicit-state (`TState`, to stay within
Idris2's own totality/stack constraints rather than a naive recursive
Tarjan) implementation of Tarjan's strongly-connected-components
algorithm over that graph. Using SCCs rather than only looking for
direct pairs is what lets `applyMutualLoop` find *indirect* cycles too
(`A -> B -> C -> A`, not just `A -> B -> A`) -- `Test10MutualLoop.idr`'s
own `cycleA`/`cycleB`/`cycleC` group specifically exercises this. Only
components of size `>= 2` are merged; a size-1 component is just an
ordinary (possibly self-recursive) function, already `Compiler.RC2.Loop`'s
job, and this pass leaves it alone entirely.

### `buildGroup` -- synthesising one merged function

For one SCC (`groupNames`):

1. Order members deterministically (`SortedSet.toList`, sorted by
   `Ord Name`) so tag assignment doesn't depend on SCC-traversal order
   -- a stability property that matters for reproducible output, not
   correctness.
2. `maxArity` = the largest arity among the group's members;
   `tagOf : SortedMap Name Int` assigns each member a small integer tag,
   `0..length members - 1`.
3. Mint a fresh merged function name (`freshName`, avoiding collision
   with every name already in the whole program) and fresh ids for the
   tag parameter (`tagId`) and each shared argument slot (`slotIds`,
   `maxArity` of them).
4. For each member, build its own `RConstAlt`:
   - `collectBoundIds` finds every id the member's own body binds
     internally (besides its own top-level parameters, handled
     separately below); `freshId` mints one fresh replacement per such
     id.
   - A `Renaming` maps the member's own top-level parameters onto the
     *shared* `slotIds` (not arbitrary fresh ones -- those genuinely
     *are* the merged function's real parameters now) and every
     internal id onto its own fresh replacement.
   - `renameRCExp` applies that renaming to the member's own body.
   - `rewriteGroupTailCalls` then walks the *renamed* body's own tail
     positions (via the shared `mapTailAppNames`) and replaces every
     tail call targeting *any* group member (looked up in `tagOf`,
     regardless of whether the target is this same member or a
     different one) with an ordinary tail call to the merged function
     itself, prepending the target's own tag and padding the argument
     list out to `maxArity` with `RCNull`.
5. The merged body is `RConstCase EmptyFC (RCLoc tagId) alts (Just
   crash)` -- the crash default is unreachable in practice (`tagId`
   only ever holds a value one of the `alts` produced), kept as a
   defensive `RCrash` rather than an unchecked partial match.
6. Each original member becomes a thin wrapper: `MkRCFun args_i
   (RAppName ... mergedName (tag :: padded args))`.

### Ownership: pure renaming, not a fresh decision

`Compiler.RC2.RC`'s `annotate` (Phase 2) already decided every member's
own dup/drop/move behaviour for its original arguments and locals,
*before* this pass ever runs -- merging doesn't change any of that, it
only changes *where a tail call lands*. `renameRCExp`'s own guarantee
(a pure substitution, existing `RDup`/`RDrop`/`RFree` nodes just move
to their new id along with their target) is what makes step 4 above
sound without this pass ever needing to reason about ownership itself.

The one thing this pass *does* need to get right on its own, since it's
building genuinely new tree shape that never went through `annotate`,
is the arity-padding invariant: whenever a transition enters member
`j`, slots `< arity(j)` always hold real, freshly-supplied values for
`j`, and slots `>= arity(j)` are always `RCNull`. This holds
*inductively* as long as *every* transition (wrapper call or in-group
tail call) pads unused trailing slots with `RCNull` -- which
`rewriteGroupTailCalls`/the wrapper construction always does. Under
that invariant, a member's own body only ever needs to reason about its
own `[0, arity)` slots exactly as it always did (that's exactly what
`annotate` already determined for its original, pre-merge argument
list); nothing beyond that is ever read, so nothing beyond that ever
needs an extra drop this pass would have to invent. `idris2rc2_drop`/
`idris2rc2_dup`/`idris2rc2_free` on a literal `NULL` are all
runtime no-ops (confirmed against `support/rc2/memory.c` during this
work), so even a defensive drop targeting a padding slot would have
been harmless -- but the invariant means one is never even generated.

**This invariant has one real, documented interaction with the *other*
pass in this document**: native-shadow promotion, running immediately
afterward in `Compiler.RC2.Loop`, has no visibility into which slots
are "always `RCNull` for some callers" -- from its own point of view
it's just looking at the merged function's own top-level parameters
like any other function's. If some *other* group member reads its own
same-position slot natively, the whole slot gets promoted group-wide,
`RCNull` included. This produced a real crash -- see "Bugs found" below.

## Emission (`Compiler.RC2.Emit`)

Both passes above only ever decide; lowering `RLoop`/`RLoopContinue` to
C is entirely mechanical, living in `Emit.idr`.

- **`declareLoopParam`**: declares (and initialises) one loop param.
  For an unchanged `RBoxed` param whose `initVal` is literally its own
  id (the common case -- every non-promoted parameter, and every
  `MutualLoop`-merged function's own shared slots on the common path),
  this is a complete no-op beyond recording its `Rep` -- `var_N` already
  exists, already holds exactly this value, as a C function parameter;
  redeclaring it would be a C redeclaration error, not just wasted
  work. For a genuinely fresh param (any native shadow, or a
  differently-id'd Boxed one -- the latter not currently produced by
  either pass, but kept total), it reads `initVal` directly via
  `rcVarToNativeC`/`rcVarToBoxedC` rather than going through
  `declareLet`/`declareNative`: those expect an ANF-shaped computation
  recipe (`ROp`/`RPrimVal`/...) to evaluate, and `emitNativeValue` has
  no case at all for a bare existing-local read (`RV`) -- an early
  attempt at this that routed through `declareLet` hit exactly that gap
  as an `InternalError`, which is why this function bypasses that
  machinery entirely rather than trying to make `RV` a new case
  `emitNativeValue` understands generically (see "Bugs found" for why
  a generic fix there would have been the wrong shape -- the "does this
  read need a drop" question that `emitNativeValue`'s existing cases
  answer via `postDrop`/ownership context isn't something a bare `RV`
  carries any information about).

  The native-shadow declaration is also this loop param's *last* use of
  the original, still-Boxed parameter anywhere in the whole function
  (`Compiler.RC2.Loop`'s own rewrite already redirected every other
  reference to the fresh shadow) -- so if `initVal` is still Boxed at
  this point, it's dropped right here, exactly once. This drop, and the
  unboxing read immediately before it, are both guarded by a runtime
  `NULL` check (`(initValName == NULL) ? 0 : (...)`) -- see "Bugs
  found" for why this guard exists and why it's cheap enough to apply
  unconditionally rather than trying to prove it's only needed for
  `MutualLoop`-merged functions specifically.

- **`emitLoopInto`**: lowers `RLoop` itself -- declares every loop param
  (`declareLoopParam`, a no-op for the common case above), emits a
  `loop:;` label, records the loop's own param list into a `Ref
  LoopParams (List (Int, Rep))` (empty until a loop is actually
  entered, consulted only by `tryEmitLoopContinue` below), then
  recurses into `body` via the same `Sink`/`TailPositionStatus`-aware
  `emitInto` every other construct in this module goes through.

- **`tryEmitLoopContinue`**: lowers `RLoopContinue` -- for each new
  value, snapshots it into a temporary first (a plain
  simultaneous-assignment safeguard against aliasing, e.g. `f x y = f y
  x`; nothing here is an ownership decision, `annotate` already decided
  every argument's dup/move before `Compiler.RC2.Loop` ever ran),
  rendering via `rcVarToBoxedC` or `rcVarToNativeC ty` per *that specific
  loop param's own* `Rep` (read back from `LoopParams`) -- already
  fully generic over `RBoxed`/`RNative`/`RInlineNative`, since it was
  written this way from the start rather than retrofitted for native
  shadowing specifically. Then reassigns each loop param variable from
  its own temporary and emits `goto loop;`.

## Bugs found and fixed (chronological)

1. **`Renaming`'s visibility (`export` vs. `public export`).** Moving
   `Renaming`/`renameRCExp`/`collectBoundIds` from `MutualLoop.idr` (a
   single-module-private definition) into `Loop.idr` as a *shared*,
   cross-module utility initially used plain `export`. `MutualLoop.idr`'s
   own `buildGroup` (`let ren : Renaming = SortedMap.fromList (...)`)
   failed to typecheck with `Can't solve constraint between: SortedMap
   Int Int and Renaming` -- `export` exposes a name's *type signature*
   across a module boundary but not its *definition*, so `Renaming` was
   opaque to unification outside `Loop.idr` even though it's a plain
   type alias. Fixed by making the alias `public export`.
2. **The `RDup`-wrapped-`ROp` eligibility miss.** As described above
   under "Native-shadow promotion": the first version of the
   eligibility scan pattern-matched an `RLet`'s own `value` directly
   against `ROp`, missing every parameter used more than once (since
   `annotate` wraps a shared operand's value in a leading `RDup`).
   Diagnosed by adding a temporary `Debug.Trace.trace` dump of the
   candidate loop body (rendered via a temporarily-exported
   `Compiler.RC2.Pretty.prettyExp`, see `doc/reading-the-ir.md`) right
   before the eligibility check in `applyLoop`, comparing what the scan
   *should* have found against what it actually found for
   `BenchLoop.idr`'s own `sumTo` -- the discrepancy pointed straight at
   the unhandled `RDup` wrapper. Fixed by `opNativeUsesThrough`, peeling
   `RDup`/`RDrop`/`RFree`/`RReleaseReuse` before checking for `ROp`,
   mirroring `Emit.idr`'s own `emitNativeValue`'s peeling exactly.
3. **`RConstCase`'s scrutinee assumed always-Boxed.** `emitConstCaseInto`
   (both its integer-switch fast path, using `idris2rc2_extractInt`-style
   extraction, and its string/double-equality-chain path, dereferencing
   a boxed `IDRIS2RC2_Double`/`IDRIS2RC2_String` struct field for `Db`/
   `Str` alts) read its own scrutinee `sc` via a bare `varName sc`,
   assuming it was always a genuine `IDRIS2RC2_Value*` -- true for every
   case `RC.idr`'s own Phase 1/2 ever produce, since a case scrutinee
   was never previously anything but an ordinary function argument or
   Boxed intermediate. Once a loop parameter pattern-matched against a
   literal constant (a countdown's own `0` check -- exactly
   `BenchLoop.idr`'s own `sumTo`) could become a native shadow, this
   assumption broke: the generated C tried to pass a raw `int64_t`
   where `idris2rc2_extractInt` expects an `IDRIS2RC2_Value *`, a
   `-Wint-conversion` compile error caught immediately on the very
   first end-to-end test after native-shadow promotion landed. Fixed by
   making both paths `Rep`-aware: `scRep <- repOfLocal sc`, then read
   `sc` via `rcVarToNativeC`/`rcVarToBoxedC` as appropriate rather than
   a bare `varName`.
4. **`MutualLoop`'s `RCNull` arity padding reaching a native-shadowed
   slot -- two separate crash sites, two separate fixes.** As
   described in `MutualLoop`'s own section above: a merged function's
   shared slot can be promoted to `RNative` because *some* group member
   reads it natively, even though *other* members only ever receive
   `RCNull` there (their own arity is smaller). Found via
   `Test10MutualLoop.idr`'s own differing-arity `stepA`/`stepB` group
   (`stepA : Nat -> Int -> Int -> Int`, `stepB : Nat -> Int -> Int`),
   which segfaulted after native-shadow promotion landed even though
   every other test still passed.
   - **Site 1 -- mid-loop, via `RLoopContinue`**: `tryEmitLoopContinue`
     unconditionally calls `rcVarToNativeC ty v` for a native-Rep'd
     loop param's new value, and `rcVarToNativeC`'s own `RBoxed` branch
     (`nativeUnbox ty (varName l)`) doesn't special-case `RCNull` --
     for a literal `NULL`, this generated `idris2rc2_to_i64(NULL)`, a
     null-pointer dereference inside the runtime accessor. Fixed with a
     dedicated `rcVarToNativeC _ RCNull = pure "0"` clause, ahead of
     the general case: `RCNull` here is never a value actually read --
     `MutualLoop`'s own invariant (a smaller-arity member never
     references its own unused trailing slots) guarantees this
     specific value is dead on the path that receives it, so *any*
     value is safe there, and `"0"` is a valid literal for every native
     C type this can be (`int64_t`, `double`, unsigned widths, all
     accept a bare `0`).
   - **Site 2 -- loop entry, via `declareLoopParam`**: a *first* fix
     (site 1 alone) didn't fully resolve the crash -- `Test10MutualLoop.idr`
     still segfaulted. The actual crash was one level earlier:
     `declareLoopParam`'s own unboxing of `initial`'s value (reading
     the merged function's own top-level parameter, at genuine function
     entry, *before* the loop's tag dispatch even runs) is unconditional
     -- when `Main.stepB`'s own thin wrapper calls the merged function
     with its own unused trailing slot padded to literal `NULL`, that
     `NULL` reaches `declareLoopParam`'s `RNative` branch regardless of
     which tag was actually passed, and `rcVarToNativeC`'s (already
     patched) `RCNull` clause doesn't apply here -- at the IR level this
     is an ordinary `RCLoc`, whose *runtime* value merely happens to be
     `NULL`, not a statically-known `RCNull` constant. `Compiler.RC2.Loop`
     has no visibility into `MutualLoop`'s own padding scheme at all
     (by design -- see the pipeline-position discussion above), so it
     can't exclude this case from eligibility in the first place. Fixed
     by a runtime guard at the one place that actually needs it:
     `declareLoopParam`'s own unboxing (and the drop right after it)
     wrapped in `(initValName == NULL) ? 0 : (...)`. Cost: one
     comparison, once per function *entry* (not once per iteration), so
     applying it unconditionally (rather than trying to prove it's only
     needed for `MutualLoop`-merged functions) is not a meaningful
     regression even for the overwhelming majority of calls where it's
     provably unnecessary.

   Both fixes were verified against the full matrix again: 19/19
   refc-suite, all smoke tests (`Test1Basics.idr`-`Test10MutualLoop.idr`),
   all benchmarks, byte-for-byte/crash-free against `idris2 --cg refc`.

## Known limitation: native-shadow eligibility stops at bare top-level scalars

Measured against a real third-party package
(`idris2-missing-containers`'s hash algorithms -- see `rc2/BENCHMARKS.md`'s
2026-08-14 entry for the full numbers): a loop param only gets promoted
if it's *itself* a native-eligible-typed local read directly as an
`ROp`/`RCmpCase` operand. A common real-world pattern this misses
entirely is a numeric state wrapped in a single-field, `newtype`-style
constructor (e.g. `data FNV1a = MkFNV1a Bits64`, the pattern every
`HashAlgorithm` instance in that package uses), where the loop's own
top-level parameter is the *constructor*, and the native value only
appears after an explicit destructure inside the loop body.
`nativeArgType` never sees past that destructure to attribute the
native use back to the top-level parameter, so such a parameter always
stays `RBoxed` -- correctly conservative (nothing is broken), just not
as effective as it could be.

A plausible extension: recognize "loop param `p`'s only structural uses
are all `case p of MkX v => ...`-shaped destructures of the same
single-field constructor, and `v` is itself native-eligible," and
shadow-promote the *field*, re-wrapping (`con MkX [shadow]`) at any
Boxed-context use. Not attempted here -- scoping and correctness (the
constructor's own tag/shape still needs representing on the "runs
once" -- entry -- side, which is a genuinely different shape of rewrite
than a bare scalar's unbox-once-at-entry, since the "does this value
exist as this exact constructor everywhere along every path" question
that requires answering is closer in spirit to `Compiler.RC2.Reuse`'s
own eligibility analysis than to anything this document's own
`nativeArgType` currently does) would need its own dedicated design
pass, not a small extension of the current one.

Two other, unrelated reasons the same benchmark's dominant costs stay
unaffected regardless, worth keeping in mind before assuming a fix to
the above alone would move the needle much on that specific benchmark:

- Interface-dispatched comparisons (`Ord`'s `<=`, etc.) never fuse into
  `RCmpCase` -- that fusion only recognizes a direct `PrimFn` comparison,
  not a call through a typeclass method (see
  `doc/native-type-inference.md`'s "Comparisons are a separate, narrower
  mechanism" section). A native-shadowed loop counter still gets
  re-boxed just to be passed into such a comparison.
- `IOHashMap`'s own write/read path is dominated by `IORef`/array
  access and constructor-list bucket traversal, not a numeric
  accumulator loop at all -- native-shadowing, however extended, was
  never going to reach either of those; that's squarely
  `TODO.md`'s "Dual calling convention" gap (native representations
  never crossing an ordinary, non-loop call boundary) instead.

## Files

- `rc2/src/Compiler/RC2/Loop.idr` -- `mapTailAppNames` (shared),
  `collectBoundIds`/`Renaming`/`renameRCExp` (shared),
  `nativeArgType`/`nativeArgTypes`/`opNativeUsesThrough`,
  `stripOwnership`, `assignShadowIds`, `applyLoop`.
- `rc2/src/Compiler/RC2/MutualLoop.idr` -- `tailCallTargets`,
  `tarjanSCCs`/`strongConnect` (Tarjan's algorithm), `buildGroup`,
  `rewriteGroupTailCalls`, `applyMutualLoop`.
- `rc2/src/Compiler/RC2/RCExp.idr` -- `RLoop`, `RLoopContinue`.
- `rc2/src/Compiler/RC2/RC2.idr` -- `toRCDefs`'s own pipeline wiring
  (`applyMutualLoop` then `applyLoop`, in that order).
- `rc2/src/Compiler/RC2/Emit.idr` -- `declareLoopParam`, `emitLoopInto`,
  `tryEmitLoopContinue`, `LoopParams`, the `rcVarToNativeC _ RCNull`
  clause, `emitConstCaseInto`'s `Rep`-aware scrutinee handling.

## Verification methodology

1. `cd rc2 && source ../env.sh && nix-shell -p idris2 gmp pkg-config --run 'idris2 --build rc2.ipkg'`
2. `cd tests/refc-suite && nix-shell -p gcc gmp pkg-config --run './run.sh'` -- expect 19/19.
3. `tests/Test9SelfTailLoop.idr` -- self-tail-call conversion's own
   dedicated coverage: parameter swapping (aliasing hazard for the
   simultaneous-assignment temp-snapshot), multiple distinct recursive
   branches in one function, an argument passed straight through
   unchanged (a "move," not a recompute), and confirms plain mutual
   recursion is *not* touched by this pass alone. Also, post
   native-shadow promotion, the canonical example of a mixed
   native-eligible/non-eligible-typed loop (`countDown`'s `Int` counter
   alongside its `String` passthrough) and of a loop parameter promoted
   via its `RConstCase` use rather than an `ROp`/`RCmpCase` one (see
   "Bugs found" #3).
4. `tests/Test10MutualLoop.idr` -- mutual-loop conversion's own
   dedicated coverage: differing-arity group members (slot padding --
   the specific shape that caught "Bugs found" #4), a 3-way cycle (SCC
   beyond the trivial pairwise case), a same-member transition inside a
   merged group (not just cross-member), a group member called both
   non-tail and as a first-class closure value from outside the group,
   and 300,000-500,000-deep mutual recursion with no C stack growth
   (direct evidence the `goto` conversion is actually firing, not just
   type-checking).
5. `tests/BenchLoop.idr`/`tests/BenchMutual.idr` -- generated C
   inspection (`grep -n "^IDRIS2RC2_Value \*Main_sumTo$" -A20
   build/exec/*.c` or similar) to directly confirm a loop body contains
   zero `idris2rc2_mk*`/`idris2rc2_dup`/`idris2rc2_drop` calls once
   native-shadow promotion applies to every loop-carried parameter; see
   `rc2/BENCHMARKS.md`'s 2026-08-14 entry for the resulting wall-clock
   comparison against `idris2 --cg refc` (roughly 60x/11x respectively).
6. `--directive dumprcexp` (see `doc/reading-the-ir.md`) on any
   candidate function is the fastest way to confirm, *before* looking
   at generated C at all, whether a given definition's body starts with
   `loop [...]` (converted) and which of its own params show `Native
   <ty>` in that line (promoted) -- `doc/reading-the-ir.md`'s own
   section 7/8 walks through exactly this.
