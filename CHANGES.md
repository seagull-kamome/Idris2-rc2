# Changes

Newest first. Each entry corresponds to one commit on `master`; see
`git log` for full commit messages.

## 2026-08-13 -- Avoid a synthetic let for zero-argument constructor operands

`RCLocal` gains `RCEmptyCon` (mirroring `RCConst`): a zero-argument,
tagged constructor other than `Nil`/`Nothing`/`Z`/`MkUnit` (which reuse
the existing `RCNull`/NULL representation) used as an operand now
inlines directly as a tagged-pointer constant, no `var_N` or heap
allocation. Fixed a real segfault the change surfaced: `RConCase`'s
dispatch always dereferenced its scrutinee as a heap
`IDRIS2RC2_Constructor*`, which broke once such a scrutinee could also
be a tagged pointer -- added `idris2rc2_conTag` to check first. Found
via `Prelude.Show.Prec` (a mixed nullary/non-nullary ADT) in practice,
not just `Test8EmptyCon.idr`'s own synthetic case.

## 2026-08-13 -- Move numeric.c's one-line functions into numeric.h as static inline

Lets the C compiler inline basic arithmetic/comparison/cast at call
sites instead of always paying for a real function call. Kept
`div_Integer` (real algorithm), `mpz_lsb` and its 9 dependent
`cast_Integer_to_*` callers (helper is `static`, not itself a
one-liner), and the string-conversion functions (multi-statement) in
`numeric.c`.

## 2026-08-13 -- Fuse native comparisons directly into two-way branches (RCmpCase)

A comparison (`LT`/`GT`/`EQ`/`LTE`/`GTE`) feeding straight into a
two-way Bool match now compiles to a raw C boolean embedded in the
`if`, skipping the boxed Bool Idris2's own encoding used to require.
Fixed a double-free the refactor introduced: RCmpCase's two branches
need the same ownership pre-shrinking an enclosing `RLet` normally does
for `ROp`, which an early version omitted.

## 2026-08-12 -- Elevate constructor-reuse-in-place analysis to a dedicated IR pass

Moved constructor-reuse-in-place out of `Emit.idr`'s stateful,
name-keyed map into a new `Compiler.RC2.Reuse` pass over the fully
Phase-1+2'd tree, with decisions encoded directly on the IR
(deterministic reservation naming, no lookup table). Fixed a
double-free surfaced mid-refactor: dropping a matched constructor's
scrutinee must first dup whichever of its own destructured fields
survive, regardless of whether reuse actually fires.

## 2026-08-12 -- Add cast-primitive coverage test for Double/Char/String

`Test7CastMatrix.idr` covers `Cast` combinations upstream's `integers`
test doesn't touch. Verified by hand (the environment's packaged RefC
runtime has 3 unrelated bugs blocking a direct diff).

## 2026-08-12 -- Add CLAUDE.md

Repo layout, build/test commands, and conventions for future sessions.

## 2026-08-12 -- Elide dup/drop entirely for Boxed locals of always-tagged PrimTypes

`Int8`/`16`/`32`, `Bits8`/`16`/`32`, and `Char` are always tagged
pointers at runtime, never real heap allocations, so dup/drop/free on
them are unconditional no-ops -- generating the calls was pure waste.

## 2026-08-12 -- Make ROp's operand-drop an explicit IR field instead of an Emit.idr rule

Added a `postDrop` field to `ROp`, decided once by `annotate` (Phase
2) instead of independently re-derived by both `emitRC` and
`emitNativeValue` at emission time.

## 2026-08-12 -- Reduce unnecessary variable/statement generation in native codegen

Four incremental steps to cut generated-C noise for native arithmetic:
skip a redundant temp var used only to sequence operand drops, inline
literal-valued native lets, splice single-use no-Boxed-operand op
chains into their use site, and move literal handling into Phase 1 via
`RCConst`.

## 2026-08-12 -- Add native-int width/signedness test, fix a real refcount leak it found

`Test6NativeInts.idr` exercises all 8 fixed-width integer types. Found
and fixed a leak: Boxed operands of a native-result op were never
dropped in `emitNativeValue`'s `ROp` case (only in `emitRC`'s).
Corrected `BENCHMARKS.md`'s `poly` figures, which had been measuring
this exact leak (the previously-reported "10x reduction" was really
"3x").

## 2026-08-12 -- Implement System.Clock, with clock_gettime precision

Deliberately diverges from RefC's coarse `time()`/`clock()`-based
implementation: uses POSIX `clock_gettime` for real nanosecond
resolution and an actually-monotonic monotonic clock.

## 2026-08-12 -- Implement Data.Buffer

Ported RefC's raw byte-buffer primitives. Found and fixed a real bug:
`Data.Buffer.idr` uses two FFI tags expecting different pointer
unwrapping, which rc2 was treating identically, corrupting file-buffer
I/O.

## 2026-08-12 -- Port upstream RefC regression tests, fix 6 bugs they surfaced

Ported 17 of `idris2-src`'s `tests/refc/*` programs into
`rc2/tests/refc-suite/`. Running real programs surfaced and fixed six
bugs (missing typecase name constants, a missing FFI stub, a wrong
pointer type, signed-extension and char-escaping bugs, and a signed/
unsigned GMP setter mismatch).

## 2026-08-12 -- Add explicit RDup/RFree reference-counting primitives to RCExp

`RDup`/`RFree` became first-class IR nodes alongside `RDrop`,
replacing the old per-use "borrowed" flag. Fixed two bugs the refactor
surfaced: Native locals weren't excluded from ownership tracking, and
`keepBoxedLocals`'s filter was inverted (a leak).

## 2026-08-12 -- Add rc2: independent external C code generator backend for Idris2

Initial implementation. A from-scratch external backend that never
modifies upstream `idris2`, diverging from RefC in two ways: reference
counting is a separate IR pass before C emission (Perceus/Koka-style),
and function-local numeric intermediates get native type inference.
