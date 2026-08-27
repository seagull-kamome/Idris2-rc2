# Constant constructor folding (`RCConstCon`)

A constructor whose fields are all -- recursively -- compile-time
constants (`[1,2,3,4,5]`, `Just 42`, a CAF's whole body) was, before
this pass, rebuilt as a fresh heap allocation on every evaluation:
`Main.constList` allocated five `Cons` cells every single time it was
read, even though the value never varies. `Compiler.RC2.ConstFold`
already folded arithmetic/comparisons/case-of-constant, but never
`RCon` itself. This document covers the design (`RCLocal`'s new
`RCConstCon` case, folded and staged as an immortal file-scope
static), and two bugs found and fixed while building it -- one that
made the fold silently inert, one a real memory leak.

## Design

### `RCLocal`'s new constant form

`RCExp.idr` adds a fifth `RCLocal` case alongside the existing
`RCLoc`/`RCNull`/`RCConst`/`RCEmptyCon`:

```idris2
RCConstCon : Name -> ConInfo -> (tag : Maybe Int) -> List RCLocal -> RCLocal
```

Invariant (upheld solely by `Compiler.RC2.ConstFold`, the only
producer): every element of `args` is itself one of these five
constant forms, recursively -- never a bare `RCLoc`.

### Folding (`Compiler.RC2.ConstFold`)

`foldConst` now folds `RCon` the same way it already folded
arithmetic into `RPrimVal`: if every field resolves -- directly, or
via `env` (a variable this pass already proved constant, tracked as
`SortedMap Int RCLocal` rather than just `Constant` now) -- to a
constant form, the whole `RCon` becomes `RV fc (RCConstCon ...)`. The
enclosing `RLet` case picks up a `RV`-of-`RCConstCon` fold result the
same way it already picked up a folded `RPrimVal`: insert into `env`,
drop the `RLet` entirely once nothing in `body` still references the
variable.

Two design points worth being explicit about:

- **`reuseFrom` construction is never folded.** A `RCon` already
  claiming a reuse reservation (`Compiler.RC2.Reuse` runs after
  Phase 1/2, so this can't actually happen pre-Phase-2, but the
  pattern match only matches `reuseFrom = Nothing` regardless) stays
  dynamic -- folding it would make the reservation meaningless.
- **Zero-arity `RCon` is excluded.** NIL/NOTHING/ZERO/UNIT already
  take the dedicated `RCNull` route before ever reaching `RCon`'s own
  `emitRC` case, so a genuinely-zero-arity `RCon` reaching this pass
  would need a zero-length C array in its staged static, which plain
  C doesn't allow (see `Bugs found #1` for why this mattered in
  practice, not just in theory).

**Partial folding**: a `RCon` whose fields don't *all* resolve stays
dynamic, but every field that *did* resolve is still rewritten in
place. `partialConst x = x :: constList` keeps a real runtime `Cons`
allocation for `x`, but its second field is a direct reference to the
already-staged `constList` static, not a re-read of a dead variable.

**Every other node holding `RCLocal` operands** (`RAppName`, `RApp`,
`RUnderApp`, `RExtPrim`, `RStructGet`/`RStructSet`, `ROp`,
`RCmpCase`) also gets its operands resolved against `env` now, even
though none of them fold to a value of their own. This isn't
optional -- see `Bugs found #1`.

### Staging (`Compiler.RC2.EmitUtil`)

Mirrors the existing `ConstDef` machinery (`boxedConstExpr`,
`EmitUtil.idr:637`) almost exactly: a new `ConstConDef` state
(`SortedMap RCLocal String` for dedup-by-name, paired with the
finished definition text list in staging order) is consulted by a new
`boxedConstConExpr`. Staging a `RCConstCon` recursively stages any
nested `RCConstCon` field first -- children always end up earlier in
the definition list than parents, which matters because a C static
initializer can only take the address of an *already-declared*
static (no forward references at file scope).

The staged C shape mirrors `IDRIS2RC2_Constructor`'s own layout
field-for-field, but as a fixed-size array instead of a flexible
array member (plain C has no static initializer for one):

```c
static struct {
    IDRIS2RC2_Header header;
    int32_t arity; int32_t tag; char const *name;
    IDRIS2RC2_Value *args[N];
} const constcon_7 = {
    IDRIS2RC2_STOCKVAL(IDRIS2RC2_TAG_CONSTRUCTOR),
    2, 1, NULL,
    { (IDRIS2RC2_Value*)(&idris2rc2_smallInt64[5]), NULL }
};
```

`IDRIS2RC2_STOCKVAL` is the same immortal-refcount marker
(`IDRIS2RC2_REFCOUNT_MAX`) the small-int cache and `ConstDef` values
already use -- **this is what makes the rest of the compiler's
ownership analysis (`Compiler.RC2.RC`'s `annotate`) need zero changes
of its own**: `idris2rc2_dup`/`idris2rc2_drop`'s own `REFCOUNT_MAX`
guard already makes any dup/drop on a staged value a runtime no-op,
so annotate can go on generating the same dup/drop calls it always
would for an ordinary Boxed value.

That said, three of `annotate`'s own helper functions (`RC.idr`'s
`splitBorrows`, `dropIfLastUse`, `boxedOperands`) *classify* operands
as boxed-or-not for reasons other than emitting the dup/drop call
itself (deciding whether a use needs a dup at all, deciding
`ROp`/etc.'s own `postDrop` list) -- these needed an explicit
`RCConstCon` case alongside their existing `RCConst`/`RCNull`/
`RCEmptyCon` ones, same reasoning: an immortal value never needs
tracking as an owned/borrowed variable would. `Compiler.RC2.Sink`/
`Compiler.RC2.DualABI`'s own parallel `localRepIn` helpers needed the
same one-line addition (always `RBoxed`, same as `RCEmptyCon`).

## Bugs found

### #1: the fold was almost entirely inert

The very first working version only matched `RLet fc var rep (RCon
...) body` -- a `RLet` whose value is *directly* a `RCon`. This
missed two shapes that turned out to be the common case, not the
exception:

- **ANF's own `RLet` chains nest, they don't flatten.** `[1,2,3,4,5]`
  normalizes to `RLet v0 (Cons 5 Nil) (RLet v1 (Cons 4 v0) (... RLet
  v4 (Cons 1 v3) (RV v4)))` -- reading outside-in, `v0`'s value is a
  bare `RCon`, but `v0`'s own *body* is another `RLet`, not a `RCon`.
  The direct-match version folded only the innermost cell and gave up
  the moment it saw a `RLet` as `value` instead of a `RCon`.
  **Fix**: fold `value` first (recursively), then classify the
  *fold result* -- `RPrimVal` or `RV`-of-`RCConstCon` both mean "now
  a known constant" -- rather than pattern-matching the *original*
  `value`'s shape.
- **A folded variable's uses elsewhere in the tree were never
  rewritten.** The existing arithmetic-fold `env` was consulted only
  by `ROp`/`RCmpCase`/`RConstCase` (to *compute* a folded result) --
  it never rewrote a node's own `args` in place. That was fine for
  arithmetic (a `ROp` whose fold fails just re-emits the same `args`
  unchanged, no information lost). But `RLet`'s own "drop this
  binding once `body` doesn't reference the variable anymore" check
  (`contains (RCLoc var) (freeLocalsR body')`) depends on those `args`
  actually getting rewritten -- a `RCLoc` left unresolved inside e.g.
  a `RAppName`'s argument list keeps the variable looking "still
  used" forever, permanently blocking the `RLet` (and the allocation
  it guards) from ever folding away. **Fix**: every node holding
  `RCLocal` operands (`RAppName`, `RApp`, `RUnderApp`, `RExtPrim`,
  `RStructGet`/`RStructSet`, plus `ROp`/`RCmpCase`'s own `args`) now
  resolves them against `env` too, purely so `freeLocalsR` sees the
  substitution -- none of these nodes fold to a value of their own
  from this.

Caught by comparing `--directive dumprcexpr` output before and after:
`Main.constMaybe` (a CAF whose whole body is one `RCon`, no `RLet`
wrapper at all) folded correctly from the start; `Main.constList`
(the `RLet`-chain shape above) and any use inside `Main.main` (always
reached through a `RLet` chain, `printLn constList` etc.) didn't fold
at all until both fixes landed.

### #2: `env`-splicing a non-native-eligible constant leaked memory

Once fix #1 started actually rewriting `args` in place, a second,
more serious bug surfaced: `printLn (Just 42)` where `42` defaults to
`Integer` (`BI`, GMP-backed) leaked 24+16 bytes per run
(`idris2rc2_mkIntegerLiteral` -> `idris2rc2_mkInteger` ->
`aligned_alloc`, confirmed via valgrind, confirmed absent on the
pre-this-branch baseline with the identical repro).

Root cause: `RC.idr`'s `bindOne` has a documented invariant that
`RCConst` is *only ever* produced for a `litRep`-covered
(native-eligible) `Constant` -- `BI`/`Str` always stay behind a real
`RCLoc`, specifically so `Compiler.RC2.RC`'s `annotate` keeps tracking
their ownership normally. `annotate`'s own `isBoxedOperand`/
`splitBorrows`/`dropIfLastUse` all treat **any** `RCConst` as
unconditionally non-Boxed (correct under that invariant -- a native
scalar never needs a refcount op). `ConstFold`'s `RLet` case, once it
started inserting `(var, RCConst c)` into `env` for *any* folded
`RPrimVal` and then splicing that `env` entry into other nodes' own
`args` (fix #1), broke the invariant: a `BI` (or `Str`) constant could
now reach `annotate` as a bare `RCConst` operand, get classified as
"never needs dropping", and the real heap allocation behind it
(`idris2rc2_mkIntegerLiteral`'s `mpz_t`) leaked.

**Fix**: `env` only ever gets an `RPrimVal`-folded entry when `litRep
c` is `Just _` (native-eligible) -- a folded `BI`/`Str` constant keeps
its `RLet` (and its `RCLoc` uses elsewhere), exactly as `bindOne`'s
own invariant already required. `asConstLocal` (deciding whether a
`RCon` field is "constant enough" to fold into a `RCConstCon`) has a
second, independent exclusion for the same underlying reason but a
different mechanism -- `RCConst (BI _)` specifically, because `BI`'s
own C rendering (`idris2rc2_getSmallInteger`/`idris2rc2_mkIntegerLiteral`)
is a real function call, never a compile-time constant expression a
static initializer could hold, even setting the leak aside.

Both exclusions matter independently: the `env`-registration guard
(above) protects `annotate`'s ownership tracking; `asConstLocal`'s
`BI` exclusion protects the C emission stage. Removing either one
while keeping the other would reintroduce a real bug, not just an
optimization regression.

Caught by: a from-scratch valgrind run on the extended regression
test flagged a leak that had no business existing; bisected via `git
stash` against the pre-branch baseline (`f x = x + 1; main = printLn
(f 100)`, no `RCConstCon` involved at all) to confirm it was newly
introduced, then via a temporary `Debug.Trace` in `ConstFold.idr` to
confirm exactly which `RLet` was losing its `RCLoc`.

## Scope / limitations (MVP)

- **Other top-level CAFs are not folded through.** `RAppName`
  referencing another CAF is never treated as constant, even if that
  CAF's own body folds entirely -- doing so would need whole-program
  dependency resolution (which CAF folds first if two reference each
  other) that this pass deliberately doesn't attempt yet. Only
  literal constructor nesting *within one definition's own body*
  folds.
- **`RConCase`/`RConstCase`'s scrutinee (`sc`) is never resolved.**
  Even if `sc` is provably a folded `RCConstCon`, this pass doesn't
  try to statically pick the matching branch -- `sc` stays a `RCLoc`
  reference (or whatever it already was), so a case over a
  known-constant scrutinee still compiles to a real runtime dispatch
  instead of folding away entirely. `RCon`'s own `emitRC` case, and
  `Compiler.RC2.Reuse`'s reservation logic, both still only understand
  a scrutinee as a real heap `RCLoc` -- resolving `sc` here would need
  those consumers taught to handle a `RCConstCon` scrutinee too, out
  of scope for this pass.

## Files

- `rc2/src/Compiler/RC2/RCExp.idr` -- `RCLocal`'s new `RCConstCon`
  case, `Eq`/`Ord`/`Show` instances (all three needed a `covering`
  annotation once a self-referential-through-`List` constructor
  entered the totality checker's reach -- see the instance headers).
- `rc2/src/Compiler/RC2/ConstFold.idr` -- the fold itself (`RLet`'s
  extended `case value' of`, the standalone `RCon` case, the
  `RAppName`/etc. operand-resolution cases), `asConstLocal`'s `BI`
  exclusion.
- `rc2/src/Compiler/RC2/EmitUtil.idr` -- `ConstConDef` state,
  `boxedConstConExpr`/`constConFieldExpr`, `RCLocal`-consuming helpers
  (`varName`/`repOfLocal`/`inlineExprFor`) extended with a
  `RCConstCon` case.
- `rc2/src/Compiler/RC2/Emit.idr` -- the `header` function's own
  static-definition-list emission.
- `rc2/src/Compiler/RC2/RC.idr` -- `annotate`'s own `splitBorrows`/
  `dropIfLastUse`/`isBoxedOperand`/`(RV fc v)` cases, extended to
  treat `RCConstCon` as immortal (never needs a dup/drop tracked).
- `rc2/src/Compiler/RC2/Sink.idr`, `rc2/src/Compiler/RC2/DualABI.idr`
  -- `localRepIn`'s own `RCConstCon` case (always `RBoxed`).
- `rc2/support/rc2/datatypes.h` -- `IDRIS2RC2_Constructor`'s layout
  (referenced, not modified) and `IDRIS2RC2_STOCKVAL`/
  `IDRIS2RC2_REFCOUNT_MAX` (reused as-is).
- `rc2/tests/Test17ConstFold.idr` -- regression test (merged in at the
  end of that file): full folds
  (`constList`/`constMaybe`/`nestedConst`), a partial fold
  (`partialConst`), and multi-site destructuring of the same immortal
  value (`headOf`/`tailOf`/`unwrapMaybe`, each called more than once)
  to directly exercise the dup/drop-is-a-no-op safety property.
- `rc2/tests/BenchConstConFold.idr` -- a constant ten-element list
  summed three million times; ~3.4x faster than this same rc2 build
  with the fold reverted, ~4.5x faster than real RefC.

## Verification methodology (if extending this)

1. `--directive dumprcexpr` (see `rc2/doc/reading-the-ir.md`) on any
   repro shows `RCConstCon` values as `#Name@tag(args)` (`Show
   RCLocal`'s own rendering) -- the fastest way to confirm whether a
   given definition folded fully, partially, or not at all, before
   looking at generated C.
2. Read the generated C's own static-definition section (grep
   `constcon_` in the `.c` output) to confirm dependency ordering
   (children before parents) and that `IDRIS2RC2_STOCKVAL` is present
   on every staged value, not just the outermost one.
3. **Always valgrind a from-scratch repro when extending which
   `Constant` cases (or which nodes) get spliced from `env`.** Bug #2
   above shows the failure mode is a silent leak, not a crash or a
   wrong answer -- it will not show up in ordinary output diffing.
   Bisect against a pre-change build (`git stash` the source changes,
   rebuild, rerun the same repro) if a leak's origin isn't obvious;
   don't assume a leak found while extending this pass is pre-existing
   without checking.
4. If ever resolving `RConCase`/`RConstCase`'s own `sc` against `env`
   (lifting the scope limitation above): `Compiler.RC2.Reuse` and
   `Emit.idr`'s `emitConCaseInto`/`emitConstCaseInto` both currently
   assume a scrutinee is a real heap `RCLoc` -- audit both before
   loosening this, not just the fold itself.
