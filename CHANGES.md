# Changes

Newest first. Each entry corresponds to one commit on `master`; see
`git log` for full commit messages.

## 2026-08-13 -- Add `--directive dumprcexp` to dump the final RCExp

New `Compiler.RC2.Pretty` renders the whole program's final RCExp
(after Reuse/MutualLoop/Loop -- exactly what Emit.idr consumes) as a
human-readable, indented text file, written next to the `.c` output as
`<outfile>.crexpr` whenever `--directive dumprcexp` is passed. Reuses
upstream idris2's own generic `--directive` passthrough (`session.
directives`, the same mechanism Chez/ES use for their own directives),
so this needed no changes to idris2-src.

## 2026-08-13 -- Drop braces/indentation from bare trailing case branches

Follow-up to the else-chaining removal: under `SinkReturn`, a case's
unconditioned trailing branch (formerly `else { ... }`) is now emitted
without its own `{ }` wrapper or extra indentation -- it's provably
always the last thing in its enclosing C block, so nothing needs the
tighter scope. Same for `emitCmpCaseInto`'s `whenFalse`.

## 2026-08-13 -- Drop redundant conditions/else-chaining in case codegen

Two related simplifications to `emitConCaseInto`/`emitConstCaseInto`
(new shared `emitAltChain`) and `emitCmpCaseInto`: a case with no
explicit default now skips the last alt's own condition check entirely
(coverage already guarantees it matches); and under `SinkReturn`, since
every branch is guaranteed to end in `return`/`goto`, alts no longer
need `else`-chaining at all. Together, a 2-alt case with no default in
tail position (e.g. a `Bool`-shaped match) collapses from
`if (...) {...} else if (...) {...}` to `if (...) {...} {...}`.

## 2026-08-13 -- Emit case branches straight into their real destination (Sink)

Generalized `assignInto` into a `Sink` (a variable, or `return`) so
`RConCase`/`RConstCase`/`RCmpCase` branches write directly into the
caller's real destination instead of a throwaway `switchReturnVar` that
gets copied afterward. Simplified `emitRC`'s `RAppName`/`RUnderApp`
cases too, now that `tryBuildClosureInto` always intercepts them first.

## 2026-08-13 -- Mutual tail recursion loop conversion (Compiler.RC2.MutualLoop)

Extends self-tail-call loop conversion to cycles of >= 2 mutually
tail-recursive functions. New whole-program pass merges each such
group (found via Tarjan's SCC) into one function dispatching on a tag,
with every internal transition rewritten as an ordinary self-tail-call
so `Compiler.RC2.Loop` converts it to a `goto` with no changes of its
own. Each original name becomes a thin wrapper.

## 2026-08-13 -- Self-tail-call loop conversion (Compiler.RC2.Loop)

A function's own self-recursive tail calls now compile to reassigning
parameter variables and a `goto`, instead of a closure + boxed
trampoline. `BenchLoop.idr` runs at ~68% of RefC's time (was ~90%).

## 2026-08-13 -- Fix remaining closure_N-then-copy redundancy; fix a real refcount leak it was hiding

`tryBuildClosureInto` now sees through `RLet` too, avoiding a
throwaway `closure_N` copy. Exposed and fixed a real leak: the
surrounding fallback re-ran `emitRC` on the un-peeled expression on
failure, double-emitting a wrapper's dup/drop/free.

## 2026-08-13 -- Remove keepBoxedLocals, confirmed dead code

Verified `RC.idr`'s `Owned` set never contains a Native local, so
`keepBoxedLocals`'s Emit-time re-filter could never remove anything.

## 2026-08-13 -- Avoid a synthetic let for zero-argument constructor operands

New `RCEmptyCon` `RCLocal` inlines a tagged nullary constructor as a
constant, no `var_N`/heap allocation. Fixed a segfault it surfaced:
`RConCase`'s dispatch needed `idris2rc2_conTag` to handle a scrutinee
that's now sometimes a tagged pointer, not always a heap constructor.

## 2026-08-13 -- Move numeric.c's one-line functions into numeric.h as static inline

Lets the C compiler inline them at call sites. Multi-statement
functions (`div_Integer`, string conversions) stay in `numeric.c`.

## 2026-08-13 -- Fuse native comparisons directly into two-way branches (RCmpCase)

A comparison feeding straight into a two-way Bool match compiles to a
raw C boolean in the `if`, skipping Idris2's boxed Bool encoding.

## 2026-08-12 -- Elevate constructor-reuse-in-place analysis to a dedicated IR pass

Moved constructor-reuse-in-place out of `Emit.idr`'s stateful map into
a new `Compiler.RC2.Reuse` pass, decisions encoded directly on the IR.

## 2026-08-12 -- Add cast-primitive coverage test for Double/Char/String

`Test7CastMatrix.idr` covers `Cast` combinations upstream's `integers`
test doesn't touch.

## 2026-08-12 -- Add CLAUDE.md

Repo layout, build/test commands, and conventions for future sessions.

## 2026-08-12 -- Elide dup/drop entirely for Boxed locals of always-tagged PrimTypes

`Int8`/`16`/`32`, `Bits8`/`16`/`32`, `Char` are always tagged pointers,
never heap allocations, so dup/drop/free on them were pure waste.

## 2026-08-12 -- Make ROp's operand-drop an explicit IR field instead of an Emit.idr rule

Added a `postDrop` field to `ROp`, decided once by `annotate`.

## 2026-08-12 -- Reduce unnecessary variable/statement generation in native codegen

Four incremental steps to cut generated-C noise for native arithmetic.

## 2026-08-12 -- Add native-int width/signedness test, fix a real refcount leak it found

`Test6NativeInts.idr` found a leak: Boxed operands of a native-result
op were never dropped in `emitNativeValue`'s `ROp` case.

## 2026-08-12 -- Implement System.Clock, with clock_gettime precision

Deliberately diverges from RefC's coarse `time()`-based implementation.

## 2026-08-12 -- Implement Data.Buffer

Ported RefC's raw byte-buffer primitives. Fixed a real bug: two FFI
tags expect different pointer unwrapping, which rc2 treated identically.

## 2026-08-12 -- Port upstream RefC regression tests, fix 6 bugs they surfaced

Ported 17 of `idris2-src`'s `tests/refc/*` programs into
`rc2/tests/refc-suite/`.

## 2026-08-12 -- Add explicit RDup/RFree reference-counting primitives to RCExp

`RDup`/`RFree` became first-class IR nodes alongside `RDrop`, replacing
the old per-use "borrowed" flag.

## 2026-08-12 -- Add rc2: independent external C code generator backend for Idris2

Initial implementation. A from-scratch external backend, diverging
from RefC in two ways: reference counting is a separate IR pass before
C emission (Perceus/Koka-style), and function-local numeric
intermediates get native type inference.
