# Batched drops (and dups)

A run of three or more drops in the generated C becomes calls of three to
six drops each:

```c
idris2rc2_drop6(var_1, var_2, var_3, var_4, var_5, var_6);
idris2rc2_drop3(var_7, var_8, var_9);
```

## Why

`idris2rc2_drop` is `static inline` (`idris2rc2_memory.h`): a NULL and
immediate check, the refcount release (plain or atomic, by the
process-wide flag of `hybrid-refcount.md`), and a call to
`idris2rc2_teardown` when it reaches zero. Inlined, that is about 150
bytes of machine code a drop at `-O2`; eight in a row came to 1,253
bytes, against 169 for one call that drops all eight.

Drops come in runs. A function that has bound many values and leaves
early drops all that are still live, as the `Left e -> ...` alt after
every bind of a `Core` computation does. In `rc2-norepl` (2026-11-25)
there were 197,944 drop statements, 113,325 of them in runs of three or
more.

## How

Nothing changes in the IR. `removeVars` (`Emit/Util.idr`) does not write
its drops: it holds them back in the output buffer (`Output`'s
`pending`, with their indentation). The next line `emit` writes, a
`removeVars` at another indentation, or the end of the definition
(`outputLines`) writes them first: `idris2rc2_dropN` calls of six, with
seven and eight left over split 4+3 and 5+3, and a run of one or two as
inline drops. So drops `removeVars`
writes for separate parts of a node (its `postDrop`, then the operands an
inlined expression left pending) make one run, and the order is kept.

Dups go the same way: `dupVars`, and `dupVarExtra` for a dup of one, hold
theirs back too, and a run of three or more becomes `idris2rc2_dup3`..
`dup6` calls. A held-back run is all drops or all dups, so the order of the
two never changes.

`idris2rc2_drop3`..`drop6` and `idris2rc2_dup3`..`dup6`
(`idris2rc2_memory.c`) are out of line. Each reads the process-wide flag of
`hybrid-refcount.md` once, and when single-threaded makes the plain
operation of each argument. Six is what x86-64 passes in registers. Under
clang on x86-64 and AArch64 they are `preserve_most`, so the caller keeps
its registers across the call, and `zero_call_used_regs("skip")`: a
hardened toolchain (nix's clang) zeroes the registers a function used when
it returns, which `preserve_most` would have to save first. Every variable `removeVars` drops is an
`IDRIS2RC2_Value *` already, as it compiled as the argument of
`idris2rc2_drop` under `-Werror`.

The compiler cannot tell a cold path from a hot one: a `Left` alt is an
error in `Core`, and a backtracking parser's usual case elsewhere. So
every run is batched, and the call is made cheap instead.

## Measured

`rc2-norepl`, clang `-O2` (2026-11-25); the time is `rc2-norepl` itself
generating its own C (`--directive nocc`), the mean of two runs:

| | `.o` text | C | codegen time |
|---|---|---|---|
| inline drops | 22.76 MB | 104.8 MB | 101 s |
| `idris2rc2_drop3`..`drop6` | 18.62 MB (−18.2%) | 101.4 MB | 102 s (+1%) |

Later (2026-11-26), on a master whose `.o` text was 17.36 MB and whose
codegen took 99.5 s (`bench.sh` against that same master's, run the same
day):

| | `.o` text | codegen time | `bench.sh` |
|---|---|---|---|
| drops only, one flag check, `preserve_most` | 17.36 MB | 98.3 s (−0.7%) | within noise |
| and dups of three or more | 15.44 MB (−11.0%) | 101 s (+1.5%) | within noise |

`bench.sh` stays within noise of the run before (`BenchListFuse` 6.56 s to
6.51 s, `BenchStringAlloc` 2.37 s to 2.34 s); its programs have few long
runs of drops.

Tried and dropped:

- Runs of two as well (`idris2rc2_dup2`, `idris2rc2_drop2`): 13.26 MB, but
  codegen +11% and `BenchIORef` +88%, `preserve_most` or not; pairs sit in
  hot loops, where a call costs more than it saves.
- Dups of three or more under the plain C convention: 15.47 MB, codegen
  +3%.

- One variadic `idris2rc2_dropMany(n, ...)`: 18.60 MB, but 104 s (+3%),
  `va_arg` and the variadic prologue on every call.
- The same with the variables in a compound literal array
  (`(IDRIS2RC2_Value *[]){...}`): 19.77 MB, as the caller stores each one
  to the stack first.
- Finding the runs again in the finished text of a definition: the same
  C, but the scan took 4 s more of codegen in `rc2-norepl`.
