# Changes

Newest first. Each entry corresponds to one commit on `master`; see
`git log` for full commit messages.

## 2026-08-13 -- Self-tail-call loop conversion (Compiler.RC2.Loop)

A function's own self-recursive tail calls now compile to reassigning
its parameter variables and a plain C `goto` back to the top, instead
of building a closure and going through the generic boxed trampoline.
New dedicated pass `Compiler.RC2.Loop` (mirrors Reuse's place in the
pipeline: runs on the fully Phase-1+2'd, Reuse'd tree) walks a
function's own tail positions, rewriting each self-call found into the
new `RSelfTailCall` IR node; `Emit.idr` only lowers it mechanically
(`tryEmitSelfTailCall`). Scope: self-tail-calls only, not mutual
recursion. Ownership is untouched -- `annotate` already decided each
argument's dup/move before this pass runs.

Fixed a bug found during verification: `tryEmitSelfTailCall` and
`tryBuildClosureInto` both peel RDup/RDrop/RFree/RLet wrappers looking
for their own target shape, but neither originally handled
`RReleaseReuse` (a wrapper Reuse can also introduce) -- any self-tail-
call sitting behind one (e.g. inside `Prelude.Types.mapAppend`, an
entirely ordinary shape) reached `emitRC` unconverted and hit an
internal error. Added the missing case to both.

`BenchLoop.idr` (`sumTo`) now runs at ~68% of RefC's time (previously
~90%); `BenchChain.idr`'s `loopPoly` improved similarly. Re-ran the
idris2-missing-containers external-package benchmark too (its 5 hash
algorithms are all self-tail-recursive loops): rc2's RefC-relative
margin widened from ~20% to ~30% faster (BENCHMARKS.md). Verified:
19/19 refc-suite tests pass, all smoke tests (including new
`Test9SelfTailLoop.idr` -- parameter swapping, multiple recursive
branches, an unchanged pass-through argument, and confirming mutual
recursion is correctly left unconverted) match upstream `idris2 --cg
refc` byte-for-byte, including at 100,000-500,000 recursion depth with
no stack growth (direct evidence the `goto` is a real loop, not
disguised recursion).

## 2026-08-13 -- Fix remaining closure_N-then-copy redundancy; fix a real refcount leak it was hiding

`tryBuildClosureInto` only peeled RDup/RDrop/RFree wrappers looking for
a closure-shaped tail expression, missing the common case of an RLet
standing in the way (e.g. IO's own `>>=`-continuation closures) --
those still built into a throwaway `closure_N` then copied into the
real target. Made it see through RLet too (sharing RLet's own
declaration logic, extracted as `declareLet`, with emitRC/
emitNativeValue's RLet cases).

Doing this exposed a real bug in the surrounding fallback logic: when
`tryBuildClosureInto` peeled a wrapper's side effect (a dup/drop/free
call, or now a let declaration) and then still failed to find a
closure at the end, its caller re-ran `emitRC` on the *original*
un-peeled expression, emitting that wrapper's side effect a second
time. For RDup this silently leaked one reference forever -- found via
`Prelude.Types.foldr`, an entirely ordinary shape (a Boxed let bound to
a dup-wrapped, non-tail-position call), not an exotic case. Fixed by
having `tryBuildClosureInto` return the unconsumed leftover expression
to resume from, instead of a bare success/fail flag.

Verified: 19/19 refc-suite tests pass; all smoke tests match upstream
`idris2 --cg refc` byte-for-byte; grepped every test's generated C for
repeated dup/drop/free calls on the same variable with nothing between
them -- none found (the few matches were legitimate, e.g. `x * x`
reading `x` twice); all 3 benchmarks run correctly.

## 2026-08-13 -- Remove keepBoxedLocals, confirmed dead code

Verified (TODO.md's "Architecture" note) that `RC.idr`'s `Owned` set --
the sole source of every `RDrop` node -- only ever gains members at
three sites, all of which already exclude `natives`-listed locals and
only ever insert genuine `RCLoc`s. `keepBoxedLocals`'s Emit-time
Native/RCConst/RCEmptyCon/RCNull re-filter in front of every `RDrop`
lowering could therefore never actually remove anything; removed.

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
