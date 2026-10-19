# `sort` against Chez: stacked causes (measured 2026-09-26)

Moved from `TODO.md`, which keeps the causes still open.

`Data.List.sort` of 1M pseudo-random `Int`s took 4.18s on rc2 and
1.23s on Chez. Cause 1 is fixed (`Compiler.RC2.DeadArgs`,
`rc2/doc/dead-args.md`), which brings `sort` to 3.21s, and the smaller
constructor cells of `rc2/doc/constructor-layout.md` to 3.12s. The rest remain.
Each cause was isolated by an experiment on copies of `Data.List`'s own
code:

| Variant | Time |
|---|---|
| `Data.List.sort` (before `DeadArgs`; 3.21s with it) | 4.18s |
| the same code copied into `Main` (B) | 3.21s |
| B plus one unused passthrough argument on `splitRec` | 4.19s |
| B with `order x y` replaced by `compare x y` (specialised) | 2.62s |
| B specialised to `x < y` | 2.03s |
| `x < y` version, non-atomic `dup`/`drop` + mimalloc | 0.99s |

1. **Fixed: an unused argument kept the input list alive** (~1.0s).
   The frontend's extra `where` arguments (`KNOWN-BUGS.md`) held the
   list's head through `splitRec`'s loop, defeating cell reuse; see
   `rc2/doc/dead-args.md`.
2. **Fixed: the comparator is never specialised.** SpecClosure now
   follows a closure forwarded from `sortBy` to `mergeBy`: `sort` 1.49s
   to 1.11s, below Chez's 1.23s
   (`rc2/doc/speculative-closure-specialization.md`, "Transitive
   specialisation").
3. **Fixed: atomic reference counts.** Plain until the program goes
   multi-threaded: `sort` 3.17s to 2.45s (`rc2/doc/hybrid-refcount.md`).
4. **glibc malloc** (-33% with mimalloc). See "a small-object
   allocator in the runtime" below.
5. **Fixed: boxed `Int`.** An `Int` within 62 bits is now immediate
   (`rc2/doc/immediate-ints.md`).

Re-measured after `DeadArgs` (3.21s):

| Variant | Time |
|---|---|
| as is | 3.21s |
| non-atomic `dup`/`drop` | 2.55s |
| mimalloc | 2.45s |
| both | 1.81s |

In the 1.81s run:
- **The TRMC'd `mergeBy` loop is 42%.** About two thirds of that is
  memory stalls:
  - loading the list cells' fields (37% of the loop);
  - touching the boxed `Int`s' refcounts to `dup` them for the
    comparator (30%).
- **The comparator call path is about 28%:** `applyClosureN`,
  `dispatchFn`, wrapper, worker, `trampoline`. There is no allocation;
  it costs about 25ns per comparison.
- **`split` is 8% and teardown 5%.**
