# Changes

Newest first. Each entry corresponds to one commit on `master`; see
`git log` for full commit messages.

## 2026-08-12 -- Implement System.Clock, with clock_gettime precision

`OSClock` is a plain `[external]` opaque type (`CFType CFUser`), so it
needed no new heap-value wrapper -- passed through as a bare
`IDRIS2RC2_Value*`. Added `support/rc2/clock.c`/`.h`, boxing a nanosecond
count via the existing `idris2rc2_mkBits64`. `GCCPU`/`GCReal` stay
unimplemented (`NULL` -> `Nothing`), matching RefC.

Deliberately diverges from RefC's own `clock.c`: RefC gets UTC/monotonic
time from `time()` (1-second resolution, and `clockTimeMonotonic` isn't
even a distinct clock -- it just calls the UTC one) and process/thread
time from `clock()`. rc2 uses POSIX `clock_gettime` throughout
(`CLOCK_REALTIME`, `CLOCK_MONOTONIC`, `CLOCK_PROCESS_CPUTIME_ID`,
`CLOCK_THREAD_CPUTIME_ID`) for real nanosecond resolution and an
actually-monotonic monotonic clock -- an intentional improvement, not a
parity bug. Ported `tests/refc/clock/TestClock.idr`; its expected output
changed accordingly (RefC's `[True, False, True, True]` -> rc2's
`[True, True, True, True]`).

## 2026-08-12 -- Implement Data.Buffer

Added a refcounted `IDRIS2RC2_Buffer` heap value (freed via `free()` once
its wrapper's refcount hits zero) and ported RefC's `buffer.c` raw
byte-buffer primitives nearly verbatim. Found and fixed a real bug while
adding it: `Data.Buffer.idr` uses two different FFI tags for buffer
operations that need *different* pointer unwrapping (`"RefC:..."`
arithmetic accessors expect the whole raw allocation including its
`int size` header; `supportC`'s `"C:...", libidris2_support` I/O
functions expect a flat pointer straight to the data, no header). rc2's
`extractValue` unwrapped both the same way, corrupting file-buffer I/O.
Fixed with a `CLang`/`CLangC`/`CLangRefC` split mirroring RefC's own.
Ported `tests/refc/buffer/TestBuffer.idr`, verified byte-identical
against RefC including the base64'd written-file check.

## 2026-08-12 -- Port upstream RefC regression tests, fix 6 bugs they surfaced

Ported 17 of `idris2-src`'s `tests/refc/*` programs into
`rc2/tests/refc-suite/` with a diff-based `run.sh` driver, so rc2 gets
checked against real-world RefC regression coverage instead of only
hand-written smoke tests. Running real programs surfaced six bugs, all
fixed:

- Missing predeclared `idris2rc2_constr_<PrimType>` name constants for
  Idris2's "typecase" feature (no backing top-level definition exists
  for these anywhere in a compiled program; RefC predeclares them too).
- Missing `refc_fork` stub for `Prelude.IO.prim__fork`'s bare
  `%foreign "C:refc_fork"` (matches RefC's own unimplemented stub).
- `stringIteratorToString`'s 4th parameter had the wrong pointer type.
- `RConstCase`'s integer-switch fast path always zero-extended, breaking
  negative `Int8`/`16`/`32` literal pattern matches.
- `escapeChar` corrupted non-ASCII char codepoints via a signed
  `(char)` cast.
- `Bits8`/`16`/`32`/`64` -> `Integer` casts used the signed GMP setter
  on unsigned values, corrupting large values (e.g. `UINT64_MAX` -> `-1`).

Also identified one case where a ported test's upstream `expected`
encoded a *known, source-commented RefC bug* that rc2 does not
reproduce, and updated that expected file to the correct result instead
of matching RefC's bug.

## 2026-08-12 -- Add explicit RDup/RFree reference-counting primitives to RCExp

Extended `RCExp`'s reference-counting model beyond `RDrop`: `RDup`
(increment) and `RFree` (unconditional, unchecked deallocation for
provably-fresh unshared allocations) are now first-class IR nodes
inserted during the `Lifted -> RCExp` conversion's ownership-analysis
phase, replacing the old per-use `RCVar` "borrowed" flag entirely. Found
and fixed two related correctness bugs the refactor surfaced: ownership
tracking didn't distinguish Native (unboxed) locals from Boxed ones
(a Native local used more than once could be wrapped in an invalid
`idris2rc2_dup` call on a raw scalar), and `Emit.idr`'s `keepBoxedLocals`
filter was inverted, excluding legitimately Boxed locals from drop lists
(a leak).

## 2026-08-12 -- Add rc2: independent external C code generator backend for Idris2

Initial implementation. A from-scratch, fully independent external
backend (`idris2-rc2`) that never modifies the upstream `idris2`
compiler, taking design cues from Idris2's own `RefC` backend (value
representation, non-atomic refcounting, closures/trampoline) but
diverging from it in two respects: reference counting is a separate IR
pass run before C emission (Perceus/Koka-style) rather than interleaved
with codegen, and function-local numeric intermediates get native type
inference so they can skip heap allocation/refcounting entirely when
provably safe. Verified via generated-code comparison against RefC: 10x
fewer memory-management operations in an arithmetic-chain benchmark (see
`rc2/BENCHMARKS.md`). Known scope boundaries: calling convention stays
fully boxed (no dual native/boxed ABI), no self-tail-call loop
conversion, comparisons still box their `Bool` result.
