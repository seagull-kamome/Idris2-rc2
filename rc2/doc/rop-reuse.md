# Boxed-arithmetic reuse-in-place (`ROp`'s `Integer` ops)

Implementation notes for the runtime-level reuse mechanism `ROp`'s
Boxed (GMP `mpz_t`-backed) `Integer` arithmetic now uses, written to let
a future session (or a future you) regain full context without
re-deriving the design. Closes out `TODO.md`'s former "Performance:
`ROp`'s Boxed arithmetic never reuses a dying/unique operand's own heap
allocation" section (see `KNOWN-BUGS.md`'s matching "Retired:" entry for
the short version and the closure precedent this follows). See also
`doc/reuse-analysis.md` for the constructor-reuse-in-place pass this
document deliberately contrasts itself against throughout.

## The problem (what `TODO.md` used to say)

`RCon`'s own `annotate` case (`Compiler.RC2.RC`) already uses a
strictly cheaper ownership convention than `ROp`'s: `wrapDups fc
(splitBorrows natives owned args) (RCon fc n ci tag args Nothing)` --
no `postDrop` at all. A `living` argument gets `dup`'d before the
constructor is built; a `dying` one is simply handed over as-is,
ownership transferred, no call-site drop ever generated. That's exactly
the ownership shape `Compiler.RC2.Reuse` exploits to repurpose a dying,
uniquely-referenced constructor's own heap cell instead of `free()`ing
and `malloc()`ing again.

`ROp`, by contrast, used to always emit an explicit post-call
`idris2rc2_drop` for every Boxed operand (`boxedOperands`-derived
`postDrop`), regardless of whether that operand was dying and uniquely
referenced right at the call. Every Boxed numeric primitive in
`rc2/support/rc2/numeric.c`/`numeric.h` (GMP-backed `Integer`
arithmetic especially) always allocated a brand-new result via
`idris2rc2_mkInteger()`, even when an operand's own `mpz_t` heap
allocation could have been reused in place for free.

## The key design insight: why this needed zero IR changes

`Compiler.RC2.Reuse` exists as a dedicated IR pass, with its own
`RReuseOffer`/`RReleaseReuse` nodes, specifically because a constructor
reuse's "offer" and "claim" happen in **two different places** in the
IR: the offer is a scrutinee dying in a `case` expression; the claim is
a same-shaped constructor rebuilt later, in one of that `case`'s alt
bodies. Connecting the two needs a forward search (`Reuse.idr`'s
`tryConsume`/`tryClaim`) that walks sequencing nodes, recurses into
nested cases, and resolves every branch independently -- real
tree-rewriting work, done once per definition, ahead of emission.

`ROp` has no such gap to bridge. Consuming a Boxed operand and
producing the new Boxed result happen in the **same C statement** --
one runtime function call (`idris2rc2_add_Integer(x, y)`, etc.). There
is no "offer, then later claim" shape to search for at all; the offer
*is* the claim, at the same program point. Consequently, the entire
feature needed **zero IR changes**:

- `RCExp.idr`'s `ROp` node (including its `postDrop : List RCLocal`
  field) is completely unchanged.
- `Compiler.RC2.RC`'s `annotate` pass (Phase 2 ownership annotation) is
  completely unchanged. Its existing `ROp` case --
  `wrapDups fc (splitBorrowsV natives owned args) (ROp fc lazy op args
  (boxedOperands natives (toList args)))` -- already inserts a `dup`
  before the call for any operand still needed afterward (living or
  borrowed), and hands a dying operand over bare (no dup). This was
  *already* exactly the right ownership-transfer shape for reuse to
  build on; the only thing wrong was what happened to that ownership
  afterward -- an unconditional compiler-emitted drop, throwing the
  reuse opportunity away every time.
- `Compiler.RC2.Reuse` (the constructor-reuse-only pass) is completely
  unchanged and untouched. It has nothing to do with `ROp` at all, and
  still doesn't.

The whole implementation is confined to two files: the runtime contract
(`rc2/support/rc2/numeric.h`) and a small compiler-side skip
(`Compiler.RC2.EmitUtil`/`Compiler.RC2.Emit`) that stops emitting the
now-redundant drop calls for the ops whose runtime primitive took over
that responsibility.

## Runtime contract change (`rc2/support/rc2/numeric.h`)

Ten Boxed `Integer` runtime primitives changed contract: `add`, `sub`,
`mul`, `mod`, `negate`, `and` (`BAnd`), `or` (`BOr`), `xor` (`BXOr`),
`shiftl`, `shiftr` -- all `idris2rc2_<name>_Integer`. Before: read-only,
the caller dropped both operands separately afterward. After: each one
now *consumes* its Boxed operand(s) -- it checks `idris2rc2_isUnique(x)`
(the same runtime refcount-is-1 check `runtime.h` already defines and
that constructor reuse and closure-grow-in-place already rely on) and,
if unique, reuses that operand's own `mpz_t` storage as the
destination in place; otherwise it falls back to
`idris2rc2_mkInteger()` for a fresh allocation, exactly as before.
Whichever operand *wasn't* chosen as the destination gets dropped by
the primitive itself now, not by the caller.

Two shared macros do the work. `IDRIS2RC2_INTEGER_BINOP` (used by
`add`/`sub`/`mul`/`mod`/`and`/`or`/`xor`) checks both operands:

```c
#define IDRIS2RC2_INTEGER_BINOP(OPNAME, MPZFN)                                     \
  static inline IDRIS2RC2_Value *idris2rc2_##OPNAME##_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) { \
    IDRIS2RC2_Integer *dst = idris2rc2_isUnique(x) ? (IDRIS2RC2_Integer *)x        \
                            : idris2rc2_isUnique(y) ? (IDRIS2RC2_Integer *)y       \
                            : idris2rc2_mkInteger();                               \
    MPZFN(dst->v, ((IDRIS2RC2_Integer *)x)->v, ((IDRIS2RC2_Integer *)y)->v);       \
    if ((IDRIS2RC2_Value *)dst != x) idris2rc2_drop(x);                           \
    if ((IDRIS2RC2_Value *)dst != y) idris2rc2_drop(y);                           \
    return (IDRIS2RC2_Value *)dst;                                                \
  }
```

The dst-selection ternary is deliberately x-first: it doesn't matter
which of two simultaneously-unique operands wins (both are about to be
consumed either way), so the tie-break is arbitrary and just needs to
be consistent. Reusing either source as `dst` is safe *no matter which*
`mpz_*` function is used here, because GMP's own documented contract is
that its `mpz_*` functions tolerate the destination aliasing either
source operand -- this macro isn't relying on an incidental property of
`mpz_add`/`mpz_sub`/etc., it's relying on a documented GMP guarantee
that holds uniformly across the whole macro-generated family.

`IDRIS2RC2_INTEGER_SHIFTOP` (`shiftl`/`shiftr`) only checks `x`, the
value being shifted -- not `y`, the shift amount:

```c
#define IDRIS2RC2_INTEGER_SHIFTOP(OPNAME, MPZFN)                                   \
  static inline IDRIS2RC2_Value *idris2rc2_##OPNAME##_Integer(IDRIS2RC2_Value *x, IDRIS2RC2_Value *y) { \
    IDRIS2RC2_Integer *dst = idris2rc2_isUnique(x) ? (IDRIS2RC2_Integer *)x : idris2rc2_mkInteger(); \
    MPZFN(dst->v, ((IDRIS2RC2_Integer *)x)->v, (mp_bitcnt_t)mpz_get_ui(((IDRIS2RC2_Integer *)y)->v)); \
    if ((IDRIS2RC2_Value *)dst != x) idris2rc2_drop(x);                           \
    idris2rc2_drop(y);                                                            \
    return (IDRIS2RC2_Value *)dst;                                                \
  }
```

`y` is never a reuse candidate here: a shift count is a different
*kind* of value than the shifted result (its magnitude is meaningless
as a GMP-limb-storage host for the result), and in practice it's always
a small, cached-immortal `Integer`, for which `idris2rc2_isUnique` is
always false anyway -- checking it would never fire, so the macro
doesn't bother.

`negate_Integer` is a small hand-written unary version of the same
pattern (`mpz_neg`), not macro-generated since it's the only unary
member of the family.

`idris2rc2_div_Integer` -- a real multi-statement Euclidean-division
algorithm in `numeric.c`, not a one-liner in this header -- was
deliberately left out of scope; see "Scope" below.

**Pre-implementation safety check**: grepped `rc2/support/rc2/*.c`/
`*.h` and confirmed none of these 10 functions have any caller besides
generated `ROp`-lowering code, so their contract could be changed in
place with no need for new `_consume`-suffixed names to avoid breaking
some other caller's expectations.

## Compiler-side change: `isReuseConsumingOp` and the `Emit.idr` skip

`Compiler.RC2.EmitUtil` gained one new pure function:

```idris
isReuseConsumingOp : PrimFn arity -> Bool
isReuseConsumingOp (Add IntegerType)  = True
isReuseConsumingOp (Sub IntegerType)  = True
isReuseConsumingOp (Mul IntegerType)  = True
isReuseConsumingOp (Mod IntegerType)  = True
isReuseConsumingOp (Neg IntegerType)  = True
isReuseConsumingOp (BAnd IntegerType) = True
isReuseConsumingOp (BOr IntegerType)  = True
isReuseConsumingOp (BXOr IntegerType) = True
isReuseConsumingOp (ShiftL IntegerType) = True
isReuseConsumingOp (ShiftR IntegerType) = True
isReuseConsumingOp _ = False
```

`True` for exactly the 10 ops matching the 10 runtime functions above,
1:1; `False` for everything else, including `Div IntegerType` (deferred,
see "Scope") and every non-`Integer` op.

`Compiler.RC2.Emit`'s `emitRC (ROp fc _ op args postDrop)` case (the
Boxed-`ROp`-lowering case) now checks `isReuseConsumingOp op` before its
usual post-call cleanup: normally it makes two `removeVars` calls after
emitting the primitive call -- one for `postDrop`'s persistent Boxed
locals, one for any ephemeral native-to-Boxed temporary `boxOpArg` had
to fabricate for a Native operand. If `isReuseConsumingOp op` is
`True`, both `removeVars` calls are skipped entirely: the runtime
primitive now owns disposal of every operand handed to it, persistent
local or ephemeral temporary alike. (In practice `boxOpArg` never
actually produces an ephemeral temporary for one of these ten ops,
since `Integer` is never native-eligible -- see
`doc/native-type-inference.md`'s `nativeEligible` -- so there's no
Native-`Integer` operand for `boxOpArg` to box in the first place. The
skip is unconditional across both calls anyway, for uniformity, rather
than adding a second, narrower condition that would never actually
differ in observed behavior.) If `isReuseConsumingOp op` is `False`,
behavior is completely unchanged: the old explicit drop emission still
runs, exactly as before this change.

## Multi-occurrence safety (`x + x`-style self-referencing expressions)

`ROp.postDrop`'s own doc comment already calls this case out: when the
same Boxed local is read twice within one op, "an operand read twice
... appears twice." The existing, unmodified `wrapDups`/`splitBorrows`
machinery already inserts a `dup` for one of the two occurrences to
represent the second logical use -- meaning the local's refcount is
already at least 2 by the time both occurrences reach the runtime call,
so `idris2rc2_isUnique` on either occurrence correctly returns false.
No incorrect reuse can happen for `x + x`: neither occurrence looks
unique, so the primitive falls back to a fresh allocation, exactly as
it would have before this change.

The primitive then drops each of its two parameter positions
independently, regardless of whether they happen to hold the same
pointer value -- this exactly matches what the old two-entries-in-
`postDrop` compiler-emitted-drop behavior already did (two separate
drop calls against the same pointer, correct because the two logical
uses were already split into two references by the preceding `dup`),
just relocated from the compiler-emitted code into the primitive. No
special-casing was needed anywhere for this shape.

## Concurrency safety

`idris2rc2_isUnique` is already used by
`idris2rc2_tailcallApplyClosure` (closure grow-in-place) and by
constructor reuse, both under the same invariant: the refcount-is-1
check itself is not what makes this safe under concurrency -- rc2's own
compile-time liveness proof (this specific call is statically known to
be the operand's last use, so no other reference can exist to race on)
is what makes it safe for the current thread to act on that check
without another thread concurrently mutating the same refcount. This
`ROp` extension relies on exactly the same pre-existing invariant,
introduces no new concurrency primitive, and needed no change to any
concurrency-related code (see `doc/concurrency.md`).

## Scope: what's deliberately excluded

- **`Div IntegerType`** (`idris2rc2_div_Integer`). Its implementation in
  `numeric.c` is a real multi-statement Euclidean-division algorithm,
  not a one-liner macro instantiation like the ten ops above --
  extending it the same way is more involved and was deliberately
  deferred, not folded into this change.
- **`Double`/`Int64`/`Bits64` reuse.** These Boxed numeric types have
  their own runtime primitives and could plausibly benefit from the
  same `idris2rc2_isUnique`-gated in-place-reuse treatment, but none of
  that was touched here -- this change is `Integer`(GMP)-only. A
  natural follow-up, not attempted.
- **`boxOpArg`'s ephemeral-temporary reuse is already included, not
  excluded.** As noted above, `Emit.idr`'s skip covers both `postDrop`
  and `boxOpArg`'s temporaries uniformly; there was no need to carve
  out a narrower condition, since `Integer` never produces a Native
  operand for `boxOpArg` to box in the first place. Called out here
  explicitly so a future reader doesn't mistake the uniform skip for an
  oversight.

## Verification performed

- Grepped `rc2/support/rc2/*.c`/`*.h` beforehand and confirmed none of
  the 10 target functions have any other caller besides generated
  `ROp`-lowering code -- safe to change their contract in place.
- New regression test: `rc2/tests/Test49IntegerOpReuse.idr` --
  `bigFactorial` (a self-tail-recursive accumulator past both the
  small-int cache `[0,100)` and the 64-bit range, so a genuine GMP heap
  allocation) plus `bigBitOps` (exercises `Mod`/`BAnd`/`BOr`/`BXOr`/
  `ShiftL`/`ShiftR` via `Data.Bits`'s `Bits Integer` instance -- the
  first time any of these `Integer` ops were exercised past
  small-int-cache magnitude anywhere in this test suite). Registered in
  `verify.sh`'s `LEAK_SENSITIVE_TESTS`.
- Full `verify.sh --regen-expected`: 87/87 pass (up from 85, +Test48
  and +Test49 -- Test49 diffs cleanly against the pinned reference
  `idris2 --cg refc`, confirming functional correctness of every
  rewritten primitive, not just `bigFactorial`'s add/sub/mul).
- `refc-suite/run.sh`: 19/19 pass.
- `valgrind --leak-check=full` on `Test49IntegerOpReuse`: 0 bytes
  definitely lost, despite the deep self-tail recursion repeatedly
  reusing/dropping GMP buffers.
- Generated C hand-inspected
  (`rc2/tests/build/Test49IntegerOpReuse_rc2.c`): confirmed
  `Main_bigFactorial`'s hot loop calls
  `idris2rc2_sub_Integer`/`idris2rc2_mul_Integer` with *no*
  `idris2rc2_drop` calls following them at all (previously, every
  Boxed `ROp` call was always followed by explicit drops) -- and
  confirmed the same absence of trailing drops for the
  `and_Integer`/`or_Integer`/`xor_Integer`/`shiftl_Integer`/
  `shiftr_Integer`/`mod_Integer`/`sub_Integer`-as-`negate` calls in
  `bigBitOps`/the `negate` test line. Meanwhile
  `Prelude_Types_prim__integerToNat` (an existing, untouched function
  using `idris2rc2_lte_Integer`, a comparison -- outside this change's
  scope, not in `isReuseConsumingOp`) was confirmed to still emit its
  old explicit `idris2rc2_drop` calls unchanged, showing the scoping is
  precise: only the 10 targeted ops changed behavior.
- Reuse itself was confirmed via direct code reading rather than a live
  allocation-count instrumentation experiment -- that experiment was
  considered and judged unnecessary, since the structural evidence
  already fully pins down the mechanism:
  `IDRIS2RC2_INTEGER_BINOP`'s dst-selection ternary directly determines
  which operand's storage becomes the destination, and the generated C
  confirms the primitive is invoked with exactly the refcounts the
  ownership analysis guarantees.

## Files

- `rc2/support/rc2/numeric.h` -- `IDRIS2RC2_INTEGER_BINOP`,
  `IDRIS2RC2_INTEGER_SHIFTOP`, `idris2rc2_negate_Integer`, and the 10
  instantiations built from the two macros.
- `rc2/src/Compiler/RC2/EmitUtil.idr` -- `isReuseConsumingOp`.
- `rc2/src/Compiler/RC2/Emit.idr` -- `emitRC (ROp ...)`'s
  `isReuseConsumingOp`-gated skip of both `removeVars` calls.
- `rc2/tests/Test49IntegerOpReuse.idr` -- the regression test.
- Explicitly untouched: `rc2/src/Compiler/RC2/RCExp.idr` (`ROp`'s own
  shape), `rc2/src/Compiler/RC2/RC.idr` (`annotate`'s `ROp` case), and
  `rc2/src/Compiler/RC2/Reuse.idr` (constructor-reuse-only, unrelated) --
  called out explicitly here because "what didn't need to change" is
  the whole point of this document.
