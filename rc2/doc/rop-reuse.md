# Boxed-arithmetic reuse-in-place (`ROp`'s `Integer`/`Int64`/`Bits64`/`Double` ops)

Implementation notes for the runtime-level reuse mechanism `ROp`'s
Boxed (GMP `mpz_t`-backed) `Integer` arithmetic now uses, later
extended to Boxed `Int64`/`Bits64`/`Double` (fixed-size scalar
payloads, not GMP-backed -- see "Runtime contract change, extended"
below), written to let a future session (or a future you) regain full
context without re-deriving the design. Closes out `TODO.md`'s former
"Performance:
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

## Runtime contract change, extended: `Int64`/`Bits64`/`Double`

The "Scope" section below used to list `Double`/`Int64`/`Bits64` reuse
as "a natural but not-yet-attempted follow-up." This has now been done,
closing that out. The mechanism is structurally simpler than the
`Integer` case above, because these three types are fixed-size scalar
payloads -- `{ IDRIS2RC2_Header header; <int64_t/uint64_t/double> v; }`
-- not a GMP `mpz_t` needing its own mutation function. "Reuse in
place" for these is just overwriting the struct's own `v` field
directly and returning the same pointer; there is no GMP-style
in-place-mutate-the-limbs step to call.

### The `IDRIS2RC2_INTTYPES` split: why it had to happen

Before this change, `rc2/support/rc2/numeric.h` generated `Add`/`Sub`/
`Mul`/`ShiftL`/`ShiftR`/`BAnd`/`BOr`/`BXOr` uniformly across all 8
fixed-width int types (`Int8/16/32/64`, `Bits8/16/32/64`) via one
X-macro, `IDRIS2RC2_INTTYPES(F)`. That uniform treatment is no longer
correct once reuse-consuming ops enter the picture: `Int8/16/32` and
`Bits8/16/32` are `Types.alwaysUnboxed` (see `doc/native-type-
inference.md`) -- at the C level they're always a tagged pointer, never
a real heap allocation (`datatypes.h`'s `idris2rc2_is_unboxed`
bit-check distinguishes the two). Calling `idris2rc2_isUnique` (a raw
`->header.refCount` read) on one of these tagged values would read
through a fake pointer -- undefined behaviour, not merely wrong.

The fix was to split the one X-macro into two:

- `IDRIS2RC2_INTTYPES_TAGGED(F)` -- the 6 always-unboxed types
  (`Int8/16/32`, `Bits8/16/32`), unchanged behavior, still built from
  the original `IDRIS2RC2_DEFOP` macro. No `isUnique` check ever
  happens for these.
- `IDRIS2RC2_INTTYPES_REUSABLE(F)` -- `Int64`/`Bits64` only, the two
  fixed-width int types that are genuinely heap-allocated once their
  value moves past the small-int cache `[0,100)`.

A new macro, `IDRIS2RC2_DEFOP_REUSE(OPNAME, TY, CTY, GET, MK, OP)`,
generates the reuse-consuming versions for the reusable pair. It
follows the exact same "check `idris2rc2_isUnique` on `a`, then `b`,
else allocate fresh" shape as `IDRIS2RC2_INTEGER_BINOP` above, but
mutates `((IDRIS2RC2_##TY *)a)->v = result` directly instead of calling
a GMP function into a `dst->v` mpz_t.

`Double` is never small-int-cached at all -- `idris2rc2_mkDouble`
always allocates fresh -- so it doesn't need the tagged/reusable split
in the first place, and got its own `IDRIS2RC2_DOUBLE_BINOP(OPNAME,
OP)` macro for `add`/`sub`/`mul`/`div`.

### `Div`/`Mod` and `Neg`, this time around

`Int64`'s Euclidean div/mod and `Bits64`'s plain div/mod are trivial
one-liners in this header, unlike `Integer`'s own `idris2rc2_div_Integer`
(a real multi-statement GMP algorithm, still excluded -- see "Scope").
There was no reason to exclude `Div`/`Mod` for `Int64`/`Bits64` this
time, so both were converted to the reuse-consuming shape alongside
the rest.

`Neg` was converted for `Int64`/`Double` (hand-written unary versions,
same field-overwrite pattern as `negate_Integer`). `Bits64` has no
`negate` at all, matching pre-existing behavior -- unsigned types don't
get one.

### Compiler side: `isReuseConsumingOp` gains matching cases

`Compiler.RC2.EmitUtil`'s `isReuseConsumingOp` gained cases for
`Int64Type`/`Bits64Type`/`DoubleType`, each covering exactly the ops
that type actually has: `Bits64Type` gets the bitwise ops but no `Neg`
(no `negate` at that type); `DoubleType` gets `Add`/`Sub`/`Mul`/`Div`/
`Neg` but no `Mod`/bitwise ops (`Double` has neither) -- matching
Idris2's own set of available operations per type.

## A real bug found: `IntType` and `Int64Type` share a C name

This is the most important thing to take away from this extension, and
it deserves its own section rather than a footnote.

`EmitUtil.cPrimType` maps **both** `IntType` (Idris2's plain,
machine-width `Int`) and `Int64Type` to the identical C function name
suffix, `"Int64"`. `Add IntType` and `Add Int64Type` both lower to a
call to the exact same `idris2rc2_add_Int64` -- there is only one
runtime function, shared by two distinct `PrimType`s.

The first pass at this implementation added only the `Int64Type` cases
to `isReuseConsumingOp`, missing `IntType` entirely -- it looked like
the obvious/complete set at a glance, since `IntType` doesn't appear in
its own right anywhere in `numeric.h`. But `numeric.h`'s
`idris2rc2_add_Int64` (and its siblings) now unconditionally consume
and drop their own operands internally, for *every* caller, regardless
of which `PrimType` the IR-level call originated from. Meanwhile
`Compiler.RC2.Emit`'s `ROp` case still emitted its old explicit
post-call drop for any op `isReuseConsumingOp` didn't recognize -- which,
with `IntType` missing, meant *every plain `IntType` op*. The runtime
already dropped the operand; the compiler-emitted code then dropped it
again. This is a genuine **double-drop / use-after-free bug**, not
merely a missed optimization -- a contract change on a shared/aliased
runtime function name needs the compiler-side gate to recognize *every*
`PrimType` that maps to that same C name, not just the one that looks
like the "real" owner of it.

It was caught by a full `verify.sh` regression run: four PRE-EXISTING,
previously-passing tests -- `Test16LoopContinuePostDrop`,
`Test19LoopInvariantParam`, `Test3Data`, `Test9SelfTailLoop` -- started
producing wrong output. Not crashes: corrupted values from the
use-after-free, and still 0 bytes "definitely lost" under valgrind,
since the freed memory was reused/still mapped rather than actually
leaked. That's worth calling out as a real gap in relying on valgrind's
leak-detection alone to catch this class of bug -- a double-free/UAF
doesn't always show up as a leak.

Fixed by adding the identical set of `IntType` cases alongside every
`Int64Type` case in `isReuseConsumingOp`, with a doc comment on
`isReuseConsumingOp` itself explaining why the two `PrimType`s must
always be kept in lockstep for any op added in the future. After the
fix, full `verify.sh --regen-expected` returned to 89/89 passing.

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
- ~~**`Double`/`Int64`/`Bits64` reuse.**~~ Done -- see "Runtime contract
  change, extended: `Int64`/`Bits64`/`Double`" above. (Left struck
  through rather than deleted, so a reader following this document's
  history can see this item was the follow-up that closed itself out.)
- **Pinned-reference `negate` typo, discovered while testing this
  extension.** While writing the `Int64`/`Bits64`/`Double` extension's
  own tests (now merged into `Test49IntegerOpReuse.idr`), the pinned
  reference `idris2 --cg refc` 0.8.0's own installed
  `mathFunctions.h` turned out to define `idris2_nagate_Int8/16/32/64`
  and `idris2_nagate_Double` -- misspelled ("nagate") -- as macros,
  while that same pinned reference's own codegen emits calls to the
  correctly-spelled `idris2_negate_<...>`. Any Idris2 program using
  `negate` on a fixed-width int or `Double` type fails to *link*
  against that one pinned binary as a result. This is a defect in the
  pinned reference binary, not in rc2 (`rc2/support/rc2/numeric.h`'s
  own `idris2rc2_negate_Int64`/`negate_Double` are spelled correctly
  and unaffected), so `Test49IntegerOpReuse.idr`'s fixed-width
  extension functions simply don't exercise `negate` at all -- that
  same file's original `Integer`-typed `bigFactorial` `negate` usage
  already covers the general reuse-consuming-`Neg`
  pattern, and `Integer`'s `idris2_negate_Integer` is a real function,
  not a macro, so it isn't affected by this typo. See `TODO.md`'s
  "Pinned reference `idris2 --cg refc` 0.8.0 misspells `negate` for
  fixed-width/`Double` types" entry for the full writeup.
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

## Verification performed (extension: `Int64`/`Bits64`/`Double`)

- Regression test coverage added to `rc2/tests/Test49IntegerOpReuse.idr`
  (merged in at the end of that file) --
  `sumInt64`/`sumBits64`/`sumDouble` (self-tail-recursive accumulator
  loops past the small-int cache) plus `bitOpsInt64`/`bitOpsBits64`
  (straight-line `Data.Bits` usage: `.&.`/`.|.`/`xor`/`shiftL`/
  `shiftR`/`div`/`mod`).
- `sumInt64`/`sumBits64`/`sumDouble` turned out to mostly exercise
  `Compiler.RC2.Loop`'s own native-shadow loop promotion instead of the
  Boxed reuse-consuming primitives: the whole loop body ends up as
  plain unboxed `int64_t`/`double` C locals, confirmed by inspecting
  `rc2/tests/build/Test49IntegerOpReuse_rc2.c`'s
  `idris2rc2_worker_Main_sumInt64_0`, whose body is pure native
  arithmetic with no Boxed call at all.
- `bitOpsInt64`/`bitOpsBits64` are the ones that actually exercise the
  Boxed reuse-consuming path in practice, specifically via `div`/`mod`:
  Idris2's `Prelude.Num`'s `Integral` interface dispatch means these
  aren't inlined as a native operator the way `+`/`-`/`*`/bitwise ops
  are. `idris2rc2_worker_Prelude_Num_div_Integral_Int64_7`'s generated
  body calls `idris2rc2_div_Int64(var_0, opBox_66)` directly with no
  trailing `idris2rc2_drop` call (hand-confirmed) -- proof the
  consuming-primitive contract and the compiler-side skip are both
  correctly wired end-to-end for `Int64`, and by extension `IntType`
  (identical C name). The same pattern was independently confirmed for
  `idris2rc2_mod_Bits64`/`div_Bits64`, both present with no trailing
  drop in `rc2/tests/build/Test49IntegerOpReuse_rc2.c` at lines 877
  and 937.
- `Neg` was deliberately not exercised in the fixed-width extension
  coverage at all, due to the pinned-reference `negate` typo described
  above and in `TODO.md`.
- Full `verify.sh --regen-expected`: 89/89 pass (87 + the new
  fixed-width extension coverage; this also re-confirms the
  `IntType`/`Int64Type` double-drop fix, since it's what brought the
  four regressed tests back to passing).
- `refc-suite/run.sh`: 19/19 pass.
- `valgrind --leak-check=full` on `Test49IntegerOpReuse` (fixed-width
  extension coverage): 0 bytes definitely lost.

## Files

- `rc2/support/rc2/numeric.h` -- `IDRIS2RC2_INTEGER_BINOP`,
  `IDRIS2RC2_INTEGER_SHIFTOP`, `idris2rc2_negate_Integer`, and the 10
  instantiations built from the two macros. Also (extension):
  `IDRIS2RC2_INTTYPES_TAGGED`/`IDRIS2RC2_INTTYPES_REUSABLE` (the split
  of the former single `IDRIS2RC2_INTTYPES`), `IDRIS2RC2_DEFOP_REUSE`,
  `IDRIS2RC2_DOUBLE_BINOP`, and the hand-written `Int64`/`Double`
  `negate`.
- `rc2/src/Compiler/RC2/EmitUtil.idr` -- `isReuseConsumingOp`, including
  (extension) the `Int64Type`/`Bits64Type`/`DoubleType` cases and the
  matching `IntType` cases added by the double-drop bug fix.
- `rc2/src/Compiler/RC2/Emit.idr` -- `emitRC (ROp ...)`'s
  `isReuseConsumingOp`-gated skip of both `removeVars` calls.
- `rc2/tests/Test49IntegerOpReuse.idr` -- the regression test for both
  the `Integer` mechanism and (merged in at the end of the same file)
  the `Int64`/`Bits64`/`Double` extension.
- Explicitly untouched: `rc2/src/Compiler/RC2/RCExp.idr` (`ROp`'s own
  shape), `rc2/src/Compiler/RC2/RC.idr` (`annotate`'s `ROp` case), and
  `rc2/src/Compiler/RC2/Reuse.idr` (constructor-reuse-only, unrelated) --
  called out explicitly here because "what didn't need to change" is
  the whole point of this document.
