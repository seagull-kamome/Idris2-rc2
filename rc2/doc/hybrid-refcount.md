# Plain reference counting until the program goes multi-threaded

Status: implemented (2026-09-27), except the escape analysis at the end,
which is tracked in `TODO.md` ("thread-local-awareなdup/dop") with the
original motivation.

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

Two helpers in `idris2rc2_datatypes.h` carry the check. Each tests the
flag once, then does the whole update, `REFCOUNT_MAX` check included,
either plainly or atomically:

| Helper | Once the flag is up |
|---|---|
| `idris2rc2_rc_retain(h)` | relaxed load, relaxed add |
| `idris2rc2_rc_release(h)` | relaxed load, release subtract, acquire load at zero; true if it was the last reference |

Every refcount update in the runtime goes through them, including
`rt.c`'s:
- `dup`, `drop`, `releaseLast`;
- the closure `trampoline`, `tailcallApplyClosure`,
  `dropReuseConstructor`.

A first version had four helpers: load, add, subtract, acquire. `dup`
and `drop` then tested the flag twice, once for the `REFCOUNT_MAX` check
and once for the update. That cost `missing-containers` 1.5 points
(-14.9% instead of -16.4%).

Apart from `dup_n`'s own flag-down path, only three places touch `rc`
directly, each on an object no other thread can reach:
- a fresh allocation;
- the small-integer cache's one-time initialisation;
- the `VERIFY`s on a value already proven unique.

`dup_n`'s CAS loop runs only when the flag is up. `isUnique` does an
acquire load when the flag is up, and a plain load otherwise.

**The acquire before a teardown is a load, not a fence.** It used to be
`atomic_thread_fence(memory_order_acquire)`. ThreadSanitizer does not
model fences, so it reported every teardown that followed another
thread's release-decrement as a race: 6 of 45 runs of the
pre-existing runtime, 186 warnings over 50 runs of this one. An acquire
load of the same count is equivalent, costs one load of a line already
in cache, and TSan understands it: 0 warnings over 50 runs.

**The `REFCOUNT_MAX` checks are part of the helpers.** A first version
read `rc` directly there. Once other threads were running,
those plain reads raced with the atomic updates: TSan reported 1,289
races in one run of rc2base's `TestMVar`.

## Measurements (2026-09-27)

Each program's generated C was linked against:
- the runtime before this change (atomic);
- a runtime with every refcount operation plain;
- the runtime as implemented.

Each figure is the best of 3 runs.

| | atomic (before) | all plain | implemented |
|---|---|---|---|
| `idris2-missing-containers` | 8.11s | 6.18s (-24%) | 6.78s (-16%) |
| `sort`, 1M `Int`s | 3.17s | 2.38s (-25%) | 2.45s (-23%) |
| closures, 1M x 20 | 3.66s | 2.60s (-29%) | 2.69s (-27%) |
| map/filter, 300k x 50 | 7.31s | 6.69s (-8%) | 6.71s (-8%) |
| BenchKnownCon | 0.76s | 0.57s | 0.57s |
| BenchClosureChain | 0.17s | 0.10s | 0.10s |
| BenchPushCon | 0.31s | 0.22s | 0.24s |

- The micro-benchmarks keep almost all of the gain.
- On `missing-containers`, the flag costs 7% more instructions and 8%
  more cycles than all-plain. That is one load and test per refcount
  operation, in a program with a large generated body.
- Map/filter is bound by the input list's cache misses and `malloc`,
  not by counting.

Two variants did not help:
- gating only the updates, and leaving the fences and `dup_n`
  unconditional;
- moving the atomic path out of line (`noinline, cold`), which was
  slightly slower on the micro-benchmarks.

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
(`constructor-escape-analysis.md`). The ceiling is the gap between the
last two columns above: 8 points on `missing-containers`. Measure how
much of it the analysis reaches before building it.

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

## Tests

- `Test102MultiThreadSwitch`: the flag is down at start, and up after
  `fork`. Also under valgrind.
- `Test103MultiThreadedDirective`: it is up at start under `%cg rc2
  multithreaded`.
- rc2base `TestMultiThreadRC2`: it is up after `enableMultiThreading`,
  and a `forkJoin` afterwards still works.

**ThreadSanitizer, by hand.** Not part of `verify.sh`. The runtime and
rc2base's C were built with `-fsanitize=thread`, and linked with the
generated C of these programs:
- rc2base's `TestConcurrency` and `TestMVar`;
- `Test102` and `TestMultiThreadRC2`;
- a stress program in which eight `forkJoin` threads map over one
  shared 2,000-element list and return new lists.

Over 10 runs each, they produced no warnings. The pre-existing runtime
had fence false positives in 6 of 45 runs (see "Runtime operations").
