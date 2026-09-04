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

## Files

- `rc2/src/Compiler/RC2/RCExp.idr` -- `RCLocal`'s new `RCConstClosure`
  case, `IsConstClosureLocal`, `IsAnyConstLocal`'s fifth constructor,
  and the `Eq`/`Ord`/`Show` additions.
- `rc2/src/Compiler/RC2/ConstFold.idr` -- the new `RLet` value-
  classification arm for `RUnderApp _ n missing []`, and
  `isConstLocalProof`'s new case.
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
