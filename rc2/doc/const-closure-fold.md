# Constant closure folding (`RCConstClosure`)

An interface-dictionary-shaped CAF -- a record of closures, one per
method, each closure a bare, zero-filled partial application of a
named top-level function -- was, before this pass, rebuilt from
scratch on every call: a 6-method dictionary meant six fresh
`idris2rc2_mkClosure` allocations plus one fresh `IDRIS2RC2_Constructor`
allocation, never memoized (rc2 has no CAF-sharing of its own). This
document covers the extension that lets `Compiler.RC2.ConstFold`'s
existing `RCConstCon` folding (`rc2/doc/const-con-fold.md`) reach
through such a dictionary and collapse the whole thing into one
immortal static, plus a real correctness gap and a related
pre-existing bug this extension surfaced.

## Design

### `RCLocal`'s new constant form

`RCExp.idr` adds a sixth `RCLocal` case, alongside `RCLoc`/`RCNull`/
`RCConst`/`RCEmptyCon`/`RCConstCon`:

```idris2
RCConstClosure : Name -> (missing : Nat) -> RCLocal
```

Unlike `RCConstCon`, this is a true leaf: a zero-filled closure has no
captured arguments at all, so there's nothing nested to recurse into.
`IsConstClosureLocal` is its own narrow witness type (mirroring
`IsConstLocal`'s reasoning for `RCConstCon`), and `IsAnyConstLocal`
gains a fifth constructor, `ItIsConstClosure2`, so a dictionary field
folding to `RCConstClosure` satisfies the same `All IsAnyConstLocal
args` obligation `RCConstCon` already requires of its own fields. Only
ever constructed by `Compiler.RC2.ConstFold`.

### Folding (`Compiler.RC2.ConstFold`)

The fold itself is a single new `RLet` value-classification arm
(`ConstFold.idr:223-227`):

```idris2
RUnderApp _ n missing [] =>
    let body' = foldConst (insert var (Element (RCConstClosure n missing) ItIsConstClosure2) env) body
    in if contains (RCLoc var) (freeLocalsR body')
          then RLet fc var rep value' body'
          else body'
```

The literal-empty-args match (`RUnderApp fc n missing []`) is exactly
what distinguishes a safe-to-fold bare reference to `n` from an
unsafe-to-fold partial application capturing a possibly-dynamic value
(`RUnderApp fc n missing (x :: xs)`, which falls through to the
existing catch-all and stays a real `RLet`) -- there is nothing inside
a zero-args `RUnderApp` that could ever be non-constant.

Beyond this one arm plus the `isConstLocalProof` case that recognises
`RCConstClosure` as an `IsAnyConstLocal`, **no other code in
`ConstFold.idr` changed**. `RCon`'s own folding case (`ConstFold.idr:
245-251`, `allConstLocal` over the constructor's resolved `args`) is
untouched: it already only cared whether each field satisfies
`IsAnyConstLocal`, not which of the five (now six) constant shapes
that field takes. An interface dictionary is, structurally, just a
`RCon` whose every field happens to resolve to a `RCConstClosure`
instead of a `RCConst`/`RCEmptyCon` -- the existing machinery folds it
into a `RCConstCon` with zero new cross-definition analysis, exactly
the way it already folded `[1,2,3,4,5]` or `Just 42`.

### Staging (`Compiler.RC2.EmitUtil`)

A new `boxedConstClosureExpr` (`EmitUtil.idr:809-826`) stages a
`RCConstClosure` the first time it's seen and returns a reference to
the staged static on every later reference, deduplicating against the
same `ConstConDef` state `boxedConstConExpr` itself already uses --
once `Eq`/`Ord RCLocal` cover `RCConstClosure` (both extended by this
change), two dictionary fields folding to the same `(Name, missing)`
pair collide onto the same map key automatically, no separate dedup
table needed. Simpler than `boxedConstConExpr`: a zero-filled closure
has no captured args to stage recursively, so none of that function's
`All`-indexed plumbing is needed here.

The staged C shape is a static struct literal:

```c
static struct { IDRIS2RC2_Header header; void *fn; uint8_t arity; uint8_t filled; }
    const constclosure_7 = { IDRIS2RC2_STOCKVAL(IDRIS2RC2_TAG_CLOSURE), (IDRIS2RC2_Value *(*)())Main_greet_Dog, 1, 0 };
```

This deliberately does **not** mirror `IDRIS2RC2_Closure`'s real
layout in full. `datatypes.h`'s actual struct is

```c
typedef struct {
  IDRIS2RC2_Header header;
  void *fn;
  uint8_t arity;
  uint8_t filled;
  IDRIS2RC2_Value *args[];
} IDRIS2RC2_Closure;
```

-- ending in a flexible array member. Plain C has no static-initializer
syntax for a flexible array member, and it would be empty regardless:
`filled` is always `0` here by construction (this only ever comes from
a literal, zero-args `RUnderApp`), so there is nothing to initialize.
The staged type instead shares just the leading `header; fn; arity;
filled` member sequence and omits the array entirely -- sound because
nothing ever reads `->args[i]` for `i < filled` when `filled == 0`,
and nothing computes `sizeof(IDRIS2RC2_Closure)` against this
particular static (it's never heap-allocated or handed to anything
assuming the real flexible-array-member layout). In particular,
`idris2rc2_isUnique`/`idris2rc2_tailcallApplyClosure`'s in-place growth
branch (which would write `args[filled]`) can never fire against an
immortal (`REFCOUNT_MAX`) header -- `idris2rc2_isUnique` is a bare
`refCount == 1` check.

`IDRIS2RC2_STOCKVAL` is the same immortal-refcount marker
(`IDRIS2RC2_REFCOUNT_MAX`) `RCConstCon`'s own staged statics, the
small-int cache, and `ConstDef` values already use -- ownership
analysis (`Compiler.RC2.RC`'s `annotate`) needs no changes of its own
beyond treating `RCConstClosure` as immortal in the same handful of
classification helpers `RCConstCon` already needed one-line additions
to (`splitBorrows`/`dropIfLastUse`/`isBoxedOperand` in `RC.idr`, plus
`localRepIn` in `Util.idr`): `idris2rc2_dup`/`idris2rc2_drop`'s own
`REFCOUNT_MAX` guard already makes any dup/drop on a staged value a
runtime no-op.

## Broader applicability: every program's own entry point

This turns out to be far more broadly load-bearing than interface
dictionaries alone. A program's own `{__mainExpression:0}` entry-point
continuation is itself a zero-filled closure over a named function, so
this fold now fires in *every* rc2-compiled program, not just ones
using interfaces. The `refc-suite/callingConvention` golden file
needed regenerating for exactly this reason: every `tmp_N` name in
that file's generated C shifted up by one (`tmp_4` -> `tmp_5`, etc.),
not because any code changed shape, but because staging the
entry-point closure now consumes one tick of the same shared
`ArgCounter` that mints `tmp_N`/`constcon_N`/`constclosure_N` names
(`EmitUtil.idr`'s `getNextCounter`) -- a harmless numbering shift, not
a semantic change, but a visible fingerprint of the fold's own
universality.

## Bugs found

### #1: `Compiler.RC2.DeadCode` couldn't see into a folded closure's own reference

`DeadCode.idr`'s reachability walker, `usedFunctionNamesR`, computed
every `Name` a `RCExp` node might call or reference, but only ever
inspected `RCExp` nodes themselves -- it never looked inside an
`RCLocal`'s own fields. This was harmless before this change: no
`RCLocal` constant form ever carried a `Name` of its own (`RCConstCon`
carries a *constructor* name, a different namespace from `defs`'s
function-name keys, correctly excluded already). It became a real,
confirmed correctness gap the moment `RCConstClosure` existed -- a
folded dictionary's only remaining reference to one of its own methods
is the `Name` embedded inside a `RCConstClosure` field, invisible to a
walker that never looks past the enclosing `RCon`/`RCConstCon`'s own
`args` list at the `RCLocal` level. `DeadCode.pruneDeadDefs` would
therefore prune a method reachable *only* through a folded dictionary
field as dead code, even though the immortal static literal
`EmitUtil` generates for that field still names the method by symbol
in its own C initializer.

**Fix**: a new `usedFunctionNamesL : RCLocal -> SortedSet Name`
recurses into `RCConstClosure` (`singleton n`) and `RCConstCon`
(`concatMap usedFunctionNamesL` over its `args`), and
`usedFunctionNamesR` was rewritten from a function with a trailing
`_ = empty` catch-all into one genuinely exhaustive over every `RCExp`
constructor, calling `usedFunctionNamesL` on every `RCLocal`-typed
field it touches (`RV`'s own local, every `args`/`postDrop` list,
`RCon`'s `reuseFrom`, `RConCase`/`RConstCase`'s `sc`, and so on). The
old catch-all is what let the gap go unnoticed: a function silently
returning `empty` for whole classes of nodes it hadn't been taught
about yet is indistinguishable, from the type checker's perspective,
from a function that correctly has nothing to report. Removing the
catch-all turns any future `RCExp` constructor added without a
matching case here into a compile-time coverage error instead of a
silent reachability miss.

**Verification methodology**: confirmed by temporarily reverting the
fix (`usedFunctionNamesL` neutered back to `const empty`) and
rebuilding -- this reproduces a real C compile error, not a silent
wrong answer: `error: '...' undeclared here (not in a function)`
inside a `constclosure_N` static initializer, since the pruned
function's own C definition (and even its forward declaration) is
entirely absent from the generated `.c`. It's a compile-stage failure
rather than a link-stage "undefined reference" specifically because a
static initializer's address-of is checked by the C compiler itself,
not deferred to the linker the way an ordinary call site's reference
would be. Restoring the fix builds and passes again. The same
reverted build breaks *every* rc2 program, not just ones exercising
this gap directly -- `{__mainExpression:0}`'s own entry-point
continuation folds via this exact mechanism regardless of interfaces
(see "Broader applicability" above).

### #2: `boxedConstExpr`'s `ConstDef` dedup cache collided `I`/`I64`

A related, pre-existing bug this change newly exposed (not introduced
by it): `EmitUtil.boxedConstExpr` keyed its `ConstDef` dedup cache by
the raw `Constant`, so an `I x` and an `I64 x` of the same value --
which already render to the identical C name per `genConstant`'s own
`I`/`I64` equivalence (the same equivalence `isReuseConsumingOp`'s own
doc comment documents for `cPrimType`) -- were treated as two distinct
cache entries. Each independently staged the same
`idris2rc2_constant_Int64_...` name, producing a C redefinition. This
had never been triggered before this session, because it's only
reachable once a native-eligible literal is forced through
`boxedConstExpr` despite `litRep` already covering it -- which only
happens from inside a folded `RCConstCon` field via
`constConFieldExpr`'s own `RCConst` case (never from `inlineExprFor`'s
`RCConst` arm, which renders a native-eligible literal inline
instead), and no interface dictionary had ever fully folded prior to
this addition. Confirmed via `rc2/tests/refc-suite/integers`'s own
`Cast`/`Neg` dictionaries once folding one into a `RCConstCon` started
exercising this path.

**Fix**: a new `constDefKey : Constant -> Constant` normalizes `I x`
to `I64 (cast x)` before every `lookup`/`insert` against `ConstDef`,
leaving every other `Constant` unchanged.

## Defensive hardening: `REFCOUNT_MAX` guard in `idris2rc2_trampoline`

Not a live-bug fix (every call site into `idris2rc2_trampoline` was
traced and confirmed to only ever pass a fresh function-call result, a
freshly-`mkClosure`'d object, or an object that already passed
`idris2rc2_isUnique` -- none of which can be an immortal closure as
the code is written today), but added for symmetry/future-proofing:
`idris2rc2_trampoline`'s own refcount decrement now checks
`c->header.refCount != IDRIS2RC2_REFCOUNT_MAX` before the atomic
decrement, mirroring the guard `idris2rc2_drop` already has, against a
future caller that someday hands it an immortal closure.

## Scope / limitations

This only folds the dictionary's own *construction* cost -- the one
allocation-per-call this document is about. Per-byte *dispatch
through* the dictionary (an actual method call, `idris2rc2_applyClosure`
against a `RCLoc`-read dictionary field) is entirely unchanged, still
a boxed indirect call. That's a separate, much larger problem
(specializing the call site to the concrete method once the dictionary
value is known statically) -- see `TODO.md`'s "Performance:
interface-dictionary method dispatch stays boxed even when the
concrete instance is known" for the still-open half of that gap.

## Follow-up (commit `0e7c755`): alias propagation, and the general call-argument case

The original pass above (commit `a01eaa2`) was scoped and verified
against interface dictionaries -- a `RCConstClosure` field sitting
inside a `RCon`/`RCConstCon`. A second look this session, re-verifying
the feature end to end, found one real completeness gap and one
untested-but-already-working generalization.

### Gap: a `let`-rebinding of an already-folded closure didn't propagate

`ConstFold`'s `RLet` value-classification block already had a mirror
arm for `RCConstCon`: once `a` has folded to a constant, a further
`let b = a` must re-enter `b` into `env` as that same constant too,
not just leave `a`'s own uses resolved --

```idris2
RV _ cval@(RCConstCon {}) =>
    let body' = foldConst (insert var (Element cval ItIsConstCon2) env) body
    in if contains (RCLoc var) (freeLocalsR body')
          then RLet fc var rep value' body'
          else body'
```

(`ConstFold.idr:211-215`). No equivalent arm existed for
`RCConstClosure`, so a chain like `let a = someTopLevelFn in let b = a
in MkDict a b` folded `a` correctly but silently stopped propagating at
`b`, even though `b` denotes the exact same immortal value -- `b`
stayed a real runtime local, and `MkDict a b`'s own `b` field never
reached `RCConstCon` folding's `allConstLocal` check. Not a
correctness bug (the generated code was still valid, just a missed
fold), but a real gap in `RCConstClosure`'s completeness as first
committed.

The fix is structurally identical to the `RCConstCon` arm -- a second
`RV` case, differing only in which constant shape and witness
constructor it matches:

```idris2
RV _ cval@(RCConstClosure {}) =>
    let body' = foldConst (insert var (Element cval ItIsConstClosure2) env) body
    in if contains (RCLoc var) (freeLocalsR body')
          then RLet fc var rep value' body'
          else body'
```

(`ConstFold.idr:228-232`, immediately following the `RCConstCon` arm
and immediately preceding the `RUnderApp _ n missing []` arm that
originally produces a `RCConstClosure` in the first place).

**Verification methodology.** Getting a genuine, *surviving* `let b =
a` (a plain local-to-local alias) into rc2's own IR turned out to be
the hard part, not the fix itself: Idris2's own frontend eagerly
collapses exactly this shape before Lifted IR ever sees it (confirmed
by hand via `--directive dumplifted` -- a plain `let a = greetFn; b = a
in ...`, written directly, never reaches `Compiler.LambdaLift`'s own
output as two separate bindings, regardless of which function it's
written in). `Test72ConstFoldClosureAliasFold` reproduces it instead
via a `%noinline` passthrough helper (`mkAlias : (String -> String) ->
(String -> String); mkAlias f = f`) -- `%noinline` keeps it a real call
in *Lifted* IR (confirmed via `--dumplifted`: `Main.main`'s own
definition still shows `%let b = Main.mkAlias(!a) in ...`, a genuine
second binding), and `Compiler.RC2.Inline` -- rc2's own, separate,
Lifted-level inliner, which does not honour upstream's `%noinline` flag
-- then splices `mkAlias`'s body (bare parameter passthrough) into the
call site, turning `b`'s own value into exactly `RV fc (RCLoc a)`
before `ConstFold` ever runs. That resolves through `env` into `RV fc
(RCConstClosure ...)`, landing precisely on the new arm. Confirmed
structurally: without the arm, the test's own `MkDict a b` construction
stays a genuine `RCon` in the generated `.c` (a real
`idris2rc2_newConstructor(2, 1)` call inside `Main_main`, one field
copied from a runtime local); with the arm, `dict` folds into a single
immortal `RCConstCon` whose two fields both reference the *same*
`constclosure_N` static, and `Main_main` contains no constructor-
allocating call at all.

### Generalization: the fold is not specific to constructor fields

The original design section above frames `RCConstClosure` folding
entirely in terms of `RCon`'s own `allConstLocal` check over
constructor fields (interface dictionaries, `{__mainExpression:0}`'s
continuation). Nothing in the fold itself is actually specific to that
position, though: `RUnderApp _ n missing []` -> `RCConstClosure`
happens once, uniformly, in `RLet`'s value classification, before any
particular *consumer* of the bound variable is considered. Whatever
later reads that binding -- a constructor field, an ordinary function
call argument, anything -- reads it as whatever `resolveLocal`
resolves it to, `RCConstClosure` included.

`Test73ConstFoldClosureCallArg` confirms this for the case that
originally motivated caring about any of this: a zero-filled closure
argument passed to an ordinary function call, not a constructor field
-- the `map double [1,2,3,4,5]` shape `TODO.md` used to track as
"Dropped: closure generation for statically-known higher-order function
arguments" (see "Full resolution" below). The test's `useIt : List Int
-> List Int; useIt xs = map double xs` compiles `double`'s closure
argument into a single immortal `constclosure_N` static baked directly
into `useIt`'s own compiled body, confirmed by generated-C inspection
to have **zero** `idris2rc2_mkClosure` calls anywhere for it. Calling
`useIt` from three separate call sites in `main` (`useIt [1,2,3]`,
`useIt [4,5,6]`, `useIt [7,8,9]`) confirms the fold happens exactly
*once*, at compile time, not once per execution: all three calls
reference the identical `constclosure_N` static, none of them
allocating a fresh closure for `double` at their own call site or
inside `useIt`.

### Full resolution of `TODO.md`'s former "Dropped: closure generation..." entry

`TODO.md` used to carry a section titled "Dropped: closure generation
for statically-known higher-order function arguments", investigating
why `map double [1,2,3,4,5]`-shaped code pays for a fresh closure
allocation on every call even though `double` is a statically known
top-level function. It considered two fix directions and dropped both:

1. **Cache/immortalise the closure** -- dropped at the time on a belief
   that `idris2rc2_tailcallApplyClosure`'s non-unique branch
   unconditionally decremented a refcount with no `REFCOUNT_MAX` guard,
   making it unsafe to hand it an immortal closure. Re-checked against
   the actual source during this session's investigation: that branch
   already calls the fully-guarded `idris2rc2_drop`, so it was never
   actually unsafe. (The one real unguarded decrement was in a
   different function, `idris2rc2_trampoline`, given a matching
   defensive guard by commit `a01eaa2` for symmetry/future-proofing
   regardless -- see "Defensive hardening" above.)
2. **Specialise the callee per statically-known argument** (clone the
   generic higher-order helper once per distinct function argument) --
   dropped, independently of direction 1, because a pervasively-used
   generic helper (`map`/`filter`/`foldl`-shaped) called with many
   different functions across a program would each mint a near-
   duplicate specialised copy, trading a per-call allocation for
   unbounded generated-code-size growth. This reasoning is untouched by
   anything below -- it simply turned out not to be needed.

Direction 1's blocker turned out to be stale, and this document's own
`RCConstClosure` fold -- direction 1, in effect, applied automatically
wherever a zero-filled closure over a named function appears, not
hand-triggered per call site -- fully resolves the motivating problem,
confirmed empirically this session:

- The exact `map double [1,2,3,4,5]` shape folds into one immortal
  `constclosure_N` static with zero `idris2rc2_mkClosure` calls
  remaining for it anywhere (`Test73ConstFoldClosureCallArg`, above).
- It folds *once* at compile time, not once per execution: three
  separate call sites into a helper that itself calls `map double xs`
  internally all reference the identical static
  (`Test73ConstFoldClosureCallArg`, above).
- The one completeness gap found while re-verifying this end to end
  (`let`-rebinding not propagating past one hop) is itself now fixed
  (`Test72ConstFoldClosureAliasFold`, above).

Direction 2 (per-call-site specialization) remains correctly dropped,
for its own independent, still-valid code-size reason -- it simply
turned out not to be the direction needed, since direction 1 already
achieves the goal a different, better way: an allocation-elision
against an existing closure representation, not a code-cloning
transformation, so it costs nothing in generated-code size regardless
of how many distinct functions a generic helper is ever called with.

## Files

- `rc2/src/Compiler/RC2/RCExp.idr` -- `RCLocal`'s new `RCConstClosure`
  case, `IsConstClosureLocal`, `IsAnyConstLocal`'s fifth constructor,
  and the `Eq`/`Ord`/`Show` additions.
- `rc2/src/Compiler/RC2/ConstFold.idr` -- the new `RLet` value-
  classification arm for `RUnderApp _ n missing []`, and
  `isConstLocalProof`'s new case; plus (commit `0e7c755`) the mirror
  `RV _ (RCConstClosure {})` arm that propagates an already-folded
  closure constant through a further `let`-rebinding.
- `rc2/src/Compiler/RC2/EmitUtil.idr` -- `boxedConstClosureExpr`, the
  `constDefKey` fix in `boxedConstExpr`, and the `RCConstClosure` cases
  added to `constConFieldExpr`/`inlineExprFor`/`repOfLocal`/`varName`.
- `rc2/src/Compiler/RC2/DeadCode.idr` -- `usedFunctionNamesL`, and the
  exhaustive rewrite of `usedFunctionNamesR`.
- `rc2/src/Compiler/RC2/RC.idr` -- `annotate`'s `splitBorrows`/
  `dropIfLastUse`/`isBoxedOperand`/`(RV fc v)` cases, extended to treat
  `RCConstClosure` as immortal.
- `rc2/src/Compiler/RC2/Util.idr` -- `localRepIn`'s `RCConstClosure`
  case (always `RBoxed`).
- `rc2/support/rc2/runtime.c` -- the defensive `REFCOUNT_MAX` guard in
  `idris2rc2_trampoline`.
- `rc2/support/rc2/datatypes.h` -- `IDRIS2RC2_Closure`'s real layout
  (referenced, not modified) and `IDRIS2RC2_STOCKVAL`/
  `IDRIS2RC2_REFCOUNT_MAX` (reused as-is).
- `rc2/tests/Test69ConstFoldClosureDict` -- structural regression: a
  3-method `Greeter Dog` instance dictionary folds into a single
  `RCConstCon` of three `RCConstClosure` fields, confirmed via
  `--directive dumprcexpr` and by grepping the generated `.c` for the
  absence of any `idris2rc2_mkClosure` call building the dictionary.
- `rc2/tests/Test70ConstFoldClosureCallthrough` -- correctness/
  valgrind-cleanliness of 500 iterations of dispatch through the
  resulting immortal closure, modeled on `Test18ClosureInPlaceGrow`'s
  own rigor.
- `rc2/tests/Test71ConstFoldClosureDeadCodeSurvival` -- the `DeadCode`
  fix specifically: a method (`secret`) reachable only via a folded
  dictionary field, with a second-hop helper it alone calls, both of
  which must survive `pruneDeadDefs`.
- `rc2/tests/Test72ConstFoldClosureAliasFold` (commit `0e7c755`) -- the
  `RCConstClosure` mirror-arm fix: a `%noinline`-mediated `let`-alias of
  an already-folded closure still folds `MkDict a b` into a single
  immortal `RCConstCon`.
- `rc2/tests/Test73ConstFoldClosureCallArg` (commit `0e7c755`) -- the
  general call-argument case (`map double [1,2,3,4,5]`-shaped): a
  closure argument folds into one immortal static shared identically
  across three separate call sites, confirmed via generated-C
  inspection to require zero `idris2rc2_mkClosure` calls.
