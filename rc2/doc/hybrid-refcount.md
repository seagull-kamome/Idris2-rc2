# Plain reference counting until the program goes multi-threaded

Status: design (2026-09-27), not implemented. The original motivation
is in `TODO.md`, "thread-local-awareなdup/dop".

## Problem

Every `dup`/`drop` is an atomic read-modify-write (`concurrency.md`,
"atomic refcount"), even in a program that never starts a thread. With
every refcount operation plain instead, refcount-heavy code runs 25-30%
faster:
- `idris2-missing-containers`: 8.07s to 6.16s;
- `sort`: 3.19s to 2.37s.

## Design

### One process-wide flag

`bool idris2rc2_threaded`, false at start, says that the program may
run Idris code on more than one thread.

- **While it is false,** every refcount operation is plain.
- **Once it is true,** they are atomic, exactly as today.
- **It is set, never cleared.**

It is set in exactly these places:
1. **The runtime's own thread starts:** `refc_fork`, and rc2base's
   `forkJoin` and anything built on them (`TaskWorker`). Each sets it
   before `pthread_create`.
2. **By hand, for threads the runtime never sees.** For example, a C
   library that starts a thread and applies an Idris closure. The
   program calls `System.GC.RC2.enableMultiThreading` once, or
   `idris2rc2_enableMultiThreading()` from C, before such a thread can
   touch an Idris value.
3. **From startup,** with `%cg rc2 multithreaded` / `--directive
   multithreaded`. This is for a program whose foreign libraries start
   threads during initialisation, or that would rather not think about
   it at all.

No per-object marking and no per-function annotations. There is one
switch, and the only obligation it puts on a program is 2: say it once,
before the first thread the runtime cannot see.

### Why switching at run time is sound

Before the flag is set, only one thread runs Idris code, so plain
operations are race-free. The flag is set on that thread, before the
second thread starts. `pthread_create`, and any hand-off a C library
uses to start its own thread, synchronises the two threads, so the new
thread sees the flag already set. So does every count written before
it. From then on every operation is atomic.

The flag is a plain `bool`. It is written once, before any other thread
exists, and only read afterwards, so reading it needs no atomics.

### Header: a union

The count stays one 16-bit field, reachable two ways:

```c
typedef struct {
  union {
    _Atomic uint16_t refCount; // once idris2rc2_threaded
    uint16_t rc;               // before: plain loads and stores
  };
  uint8_t tag;
  uint8_t reserved;
} IDRIS2RC2_Header;
```

Every plain access goes through `rc`, including the `REFCOUNT_MAX`
checks and `isUnique` before the switch. That matters. A first
prototype kept the field `_Atomic` and used relaxed loads and stores
for the plain path. It got only half the gain: `missing-containers`
went from 8.07s to 7.08s, where fully plain is 6.16s. GCC does not
combine or reorder accesses to an `_Atomic` object, even relaxed ones.

### Runtime operations

Two helpers carry the check:
- `idris2rc2_rc_add(h, n)`: a plain add, or a relaxed atomic add;
- `idris2rc2_rc_sub(h)`: a plain subtract, or a release subtract.

Every refcount update in the runtime goes through them, including those
in `rt.c`:
- `dup`, `dup_n`, `drop`, `releaseLast`;
- the closure `trampoline`, `tailcallApplyClosure`,
  `dropReuseConstructor`.

The acquire fence after a count reaches zero, and `dup_n`'s CAS loop,
run only when the flag is set. `isUnique` does an acquire load when the
flag is set, and a plain load otherwise.

## Measurements (2026-09-27)

The same generated C was linked against each runtime; each figure is
the best of 3 runs.

| | atomic (today) | all plain | flag + union |
|---|---|---|---|
| `idris2-missing-containers` | 8.06s | 6.20s (-23%) | 6.68s (-17%) |
| `sort`, 1M `Int`s | 3.17s | 2.37s (-25%) | 2.44s (-23%) |
| closures, 1M x 20 | 3.67s | 2.61s (-29%) | 2.72s (-26%) |
| map/filter, 300k x 50 | 7.31s | 6.70s (-8%) | 6.71s (-8%) |
| BenchKnownCon | 0.76s | 0.56s | 0.57s |
| BenchPushCon | 0.31s | 0.22s | 0.22s |
| BenchClosureChain | 0.17s | 0.10s | 0.10s |

- The micro-benchmarks keep almost all of the gain. On
  `missing-containers`, the flag costs 7% more instructions and 8% more
  cycles than all-plain. That is one load and test per refcount
  operation, in a program with a large generated body.
- Two variants did not help:
  - fences and `dup_n` still unconditional;
  - the atomic path moved out of line (`noinline, cold`), which was
    slightly slower on the micro-benchmarks.
- map/filter is bound by the input list's cache misses and `malloc`,
  not by counting.

## Escape analysis: fixed plain operations (later)

The remaining cost is the check itself. A value that provably never
becomes reachable from another thread can take a plain `dup`/`drop`
with no check at all, whatever the flag says. Such a value is:
- a cell this function builds (`RCon`, a closure);
- used only within the function, by field reads and `case`;
- never passed to a call, stored into another object, or returned.

Such an object is only ever reached by one thread. It stays correct
even if the flag is raised meanwhile, since that thread is the only
one updating its count. Emit writes `idris2rc2_dup_local` /
`idris2rc2_drop_local` for it.

`TODO.md` already notes the catch: most such values are unboxed or
eliminated by the existing constructor escape analysis
(`constructor-escape-analysis.md`). The ceiling is the 6% between the
last two columns above. Measure how much of it the analysis reaches
before building it.

## API

rc2base, `System.GC.RC2`, next to `unsafeGCDup`/`unsafeGCDrop`:

```idris
||| Switches rc2's reference counting to atomic operations, for good.
||| Call it once before starting a thread the runtime does not know
||| about, one that will touch Idris values (a C library's thread
||| running an Idris callback). `fork`/`forkJoin` already do it.
export enableMultiThreading : IO ()

||| Whether reference counting is atomic yet.
export isMultiThreaded : IO Bool
```

C code gets `idris2rc2_enableMultiThreading()` and `idris2rc2_threaded`
in `idris2rc2_memory.h`.

## Plan

1. **Runtime and library.**
   - Runtime: the flag, the union, the helpers, and every refcount
     update routed through them.
   - Raising the flag in `refc_fork` and rc2base's thread starts.
   - The `multithreaded` directive, set in `idris2rc2_rtInit`.
   - The `System.GC.RC2` API.
2. **Tests.**
   - A new test checks that `isMultiThreaded` is false at start and
     true after `fork`, after `enableMultiThreading`, and under the
     directive.
   - The existing concurrency tests, built with `-fsanitize=thread`:
     fork, `forkJoin`, `Channel`, Mutex/Condition, and a
     `TaskWorker`-style pool through a CAF `IORef`.
   - `verify.sh` under valgrind as usual.
3. **Measure** against the table above, then decide on the escape
   analysis.
