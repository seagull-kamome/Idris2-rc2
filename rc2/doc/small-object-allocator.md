# A cell allocator for constructors and closures

Status: stages 0, 1a, 1b, 1c and 2 are implemented (`idris2rc2_pool.c`,
`idris2rc2_pool.h`, `idris2rc2_memory.[ch]`); stage 3 was measured and is not
planned (see "Stage 3, measured"). Reviewed
against the runtime on 2026-11-10; the review's findings are folded in below.
"Results" at the end has the measurements.

## Problem

Every constructor, closure and box goes through `idris2rc2_alloc`, which is
`malloc`. Measured on the rc2-built compiler building `libs/prelude`
(callgrind call counts of `stage1`, 36.9 G instructions, 2026-11-10, before the
one-block `String` layout):

| allocated by | calls | share of `malloc` calls |
|---|---|---|
| `idris2rc2_newConstructor` | 53.2 M | 72.1% |
| `idris2rc2_mkClosure` | 14.4 M | 19.5% |
| `idris2rc2_mkLazy` (a `Lazy` cell) | 2.6 M | 3.6% |
| `Data.IORef.newIORef` | 0.3 M | 0.4% |
| strings (1.6 M objects, two blocks each) | 3.2 M | 4.3% |

73.9 M allocations in a 6.6 s build, about 11 M per second. By size (rounded up
to 8 bytes): 16 bytes 25.4%, 24 bytes 31.2%, 32 bytes 16.3%, 40 bytes 13.6%,
48 bytes 5.9%; at most 48 bytes together 93.3%, at most 128 bytes 98.8%. A
24-byte cell is a two-field constructor (`::`, a pair, ...).

What it costs, from the callgrind profile of building `rc2-norepl`
(`self-hosting.md`, item 7): `malloc`/`free` take 27% of the instructions, the
reference counts 26%, the allocation wrappers 8%. Swapping in mimalloc with
`LD_PRELOAD` shortened the build of `base` by 13.5% (84.0 s to 72.7 s;
`BENCHMARKS.md`; an earlier measurement of the same swap gave 5.1%, so the
effect moves with the runtime), and a list-heavy `map`/`filter` by a factor of
six (`TODO.md`). The cause is mostly locality: tearing a list down pushes its
cells onto glibc's LIFO fastbins in scattered order, and the next allocations
pop them in that order, each pop a cache miss.

## Scope: cells only

The allocator serves the objects whose size follows from their tag and arity:

| cell | size in bytes |
|---|---|
| `Constructor` | `8 + 8 * (arity + (tag < 0 ? 1 : 0))` |
| `Closure` | `16 + 8 * arity` (room for the full arity is reserved when it is made) |
| `IORef`, and a `Lazy` cell | 16 |
| boxed `Int64`/`Bits64`/`Double` | 16 |
| `GCPointer` | 24 |

These are 95.6% of the `malloc` calls above, about 97.7% once a `String` is one
block (1.6 M calls instead of 3.2 M). Not served, and still `malloc`: `String`
(about 2% of the objects, a variable length), `Integer` (an `mpz`), `Array`,
`Buffer`, `ThreadID`, `Mutex`/`Condition`/`Semaphore`/`Barrier`/`JoinHandle`/
`Channel` and the channel nodes. A string could join later, since its size is
`16 + len + 1`; nothing below depends on leaving it out.

### The entry point must be split first (stage 0)

`idris2rc2_alloc(size)` is today the one entry of every type, so two types of the
same size (an `IORef`, a `Buffer`; a `GCPointer`, an `Array`) cannot be told
apart by size. Stage 0 adds `idris2rc2_cellAlloc` and moves exactly the cell
types onto it, with no change of behaviour (it still calls `malloc`):

| allocation site | cell? |
|---|---|
| `newConstructor`, `mkClosure`, `mkDouble`, `mkInt64`, `mkBits64` (`memory.c`) | yes |
| `newIORef` (`ioprims.c:15`), `mkLazy` (`rt.c:541`), `mkGCPointer` | yes |
| `mkInteger`, `mkArray`, `mkBuffer`, `mkThreadID`, the `String` of `cast Integer String` (`numeric.c:443`), `allocString` | no |
| `libs/rc2base`'s `Mutex`/`Condition`/`Semaphore`/`Barrier`/`JoinHandle`/`Channel` (`concurrency_util.c`) | no |

The release side is already split by tag in `idris2rc2_teardown`; only the cell
tags branch to `cellFree`, the others keep the `free(v)` at its end. The closure
shells freed by `idris2rc2_trampoline` and `idris2rc2_applyClosureN` (`rt.c`) and
`idris2rc2_releaseReuse` (`rt.h`) are cells. The channel nodes
(`concurrency_util.c`) and the thread primitives are not, and must not move.
Nothing outside the runtime frees a cell: an `%export` result is a separate copy.

### Which class

One function, `idris2rc2_poolClass(size)`, maps a size to a class (`16..128` in
steps of 8: 15 classes) or to "too big, use `malloc`". At an allocation site with
a constant arity the class is a constant and the branch is gone. A closure of
more than 14 arguments and a constructor of more than 15 fields (14 with a
name slot) are the only ones that fall to `malloc`. The release site takes the
same decision from the same tag and arity, so the two agree without looking at
the address; a cell that is in the pool is then found through its page.

## Layout

- **Segment.** 4 MiB, 4 MiB aligned (`mmap` of twice the size, trimmed), 64 pages
  of 64 KiB. Page 0 holds the **segment header**: the page descriptors and
  `freeMask`, the bitmap of the pages no heap holds. The other 63 pages hold
  cells. A segment is **never unmapped**: a thread that released a cell looks at
  the page descriptor (`owner`, `inPending`) after the cell is on `thread_free`,
  by which time the owner may have collected it, emptied the page and returned it.
  A returned page's memory goes back to the OS (`madvise`); only the header page
  of a segment stays resident.
- **Page descriptor** (128 bytes, two cache lines, in the segment header, so
  that returning a page to the OS cannot erase it). The first line is the
  owner's alone: `free` (the free list), `used`, class, state, `bump` and `end`
  (the part of the page not yet cut into cells), `base`, and the links of the
  heap's list of the class. The second is written by other threads:
  `thread_free` (an atomic stack of cells released by other threads), `owner`,
  `inPending` and `pendingNext`.
- **Heap.** One per thread, found through a `__thread` pointer that starts at a
  static *empty heap* whose `direct[k]` all point at a dummy page with an empty
  free list. So the fast path never tests for NULL: a thread that has no heap yet
  falls into the slow path, which creates it and registers the thread-exit hook.
  This also covers a C thread that calls an `%export` function. A heap holds, per
  class, `direct` (the page being allocated from), `avail` (other pages with room)
  and `full`; the list of empty pages; and `pending`, the stack of pages that
  have cells waiting on their `thread_free` (on a cache line of its own).
- **Free list link.** A free cell keeps its next pointer in its **second word**
  (offset 8), not in the header, so the header (reference count, tag) stays
  readable for check mode and for `isUnique`.

```c
// allocate: heap -> current page -> head of its free list
pg = tl_heap->direct[k]; c = pg->free;
if (likely(c)) { pg->free = c->next; pg->used++; return c; }
return slow_path(k);

// release: the page is found through the segment header
seg = p & ~(SEG - 1); pg = &seg->pages[(p - seg) / PAGE];
if (atomic_load_relaxed(&pg->owner) == tl_heap) {   // own page: plain
  c->next = pg->free; pg->free = c; --pg->used;
  if (pg->state != ACTIVE || (pg->used == 0 && pg != tl_heap->direct[pg->klass])) page_after(pg); }
else push_remote(pg, c);                            // anything else: remote
```

- **The slow path**, in this order: (1) extend `free` by the next 64 cells from
  the page's bump pointer, in address order, so a fresh page is touched as it is
  used, its cells come out in sequence and the fast path stays one pop; (2) drain
  `pending` and take the page's `thread_free` (`atomic_exchange`) into `free`;
  (3) if the page is exhausted, put it on the `full` list and take another: an
  `avail` page, an empty page of the heap, an abandoned page of the class
  (adopting it), and only then a new page; before a new page is taken the
  abandoned pages of every class that have something on `thread_free` are swept,
  so that a producer and a consumer reuse what the consumer released instead of
  growing the heap.
- **Full pages** leave the class's list and go on a *full* list; the first release
  into a full page puts it back on `avail`.
- **`used`** counts the cells of the page that are alive **or still on
  `thread_free`**. Only the owner changes it: a local release does `--used`, a
  collection of `thread_free` does `used -= n`. So a page with `used == 0` has
  nothing left on `thread_free`, and only then may it be emptied. A remote push
  never touches `used`.
- **The handshake with `pending`.** A pusher pushes the cell onto `thread_free`
  (compare-and-swap), then sets the page's `inPending` flag (it skips the
  exchange if the flag is already set) and, if it was clear, pushes the page onto
  its owner's `pending`. The owner takes the whole `pending` stack with
  `atomic_exchange`, and for each page clears the flag *before* it collects
  `thread_free`: a push that comes after the clear sees the flag clear and queues
  the page again, one that came before is collected. All of it is `seq_cst`, and
  the collection that follows the clear is unconditional: the relaxed
  "is there anything" pre-check used elsewhere would let a pusher that saw the
  flag set and a collector that saw `thread_free` empty both walk away.
- **Stale entries.** A page can be emptied and returned while an entry for it is
  still on its old owner's `pending` (the pusher's two steps are not atomic).
  `pageReturn` makes `owner` the `abandonedHeap` sentinel before the page can be
  taken again, and `pageInit` publishes the new owner last, so the old heap's
  `owner == h` test fails for the entry and the old heap does not touch the page.
  A heap does not return an empty page whose `inPending` is set; but a late
  pusher can still set the flag on a page that is already returned. The only harm
  is then that the new owner's page has `inPending` set until the old heap next
  drains, so its remote releases wait for a collection that does not come from
  the queue: the new owner finds them when it runs out of room in its direct page
  or looks over its first few full pages before taking a new one, and a purge
  finds all of them.
- A cell on a page that was *abandoned* is released by the same remote path:
  `owner` is the `abandonedHeap` sentinel, whose `pending` is `POOL_DEAD`, and the
  owner test is an atomic load, so a thread that has just lost its heap does not
  take the page for its own.

## What it does for constructors and for short-lived lists

- **LIFO reuse.** A cell dropped on a page is the next one that page hands out,
  still in cache. A loop that builds a `::` and drops it a step later runs in a
  handful of cache lines.
- **Cells of one list sit together.** A new page is used in address order, so
  the cells of a list built in one go (a TRMC loop fills them front to back) are
  neighbours, and a traversal gets the hardware prefetcher instead of a miss per
  cell.
- **Constant sizes.** `newConstructor(2, 1)` becomes a free-list pop and a store
  of one constant 8-byte header word (reference count 1, tag, `arity`, `tag`).
- **Teardown.** A list is already freed by a loop over its tail. What goes is the
  call into `free` and its bookkeeping; the `switch` on the tag and the walk over
  the children stay (`teardown` costs about 47 instructions per object today,
  of which `free` is a part, not all).
- **A remote release is batched.** A chain of cells freed by another thread
  usually sits on one page. A thread keeps one batch (a page, and the cells it has
  released to it, linked but not yet on `thread_free`) and pushes it with one
  compare-and-swap when it has 64 cells, when the next cell is on another page,
  when it takes the slow path of an allocation, in `idris2rc2_poolPurge()`, and in
  every call of its thread-exit hook. A thread that only releases (a consumer)
  gets a heap on its first remote release, for that hook. The cells of a batch
  still count in the page's `used`, so the page cannot be emptied under them. The
  cost is that a thread that blocks holds back up to 63 cells and the page they
  are on until it runs again; and cells released by a key destructor that runs
  after the last call of the thread's own destructor stay in the batch.
- **Inline allocation.** `idris2rc2_newConstructor` and `idris2rc2_mkClosure` are
  `static inline` in `memory.h`: with a constant arity the class is a constant, the
  allocation is the pop of a free list, and the header (reference count, tag,
  arity, constructor tag) is one 8-byte store. The release is not inlined:
  forcing `dup`/`drop` inline once grew the compiler from 15 to 38 MB, and the
  inline allocation grows it by 3%.
- **A candidate, not in the first stages: recycle at allocation.** On the last
  release of a chain's head, keep the head instead of freeing it and tear its
  children down one per allocation, handing the cell just emptied to the next
  allocation. A free-and-allocate pair becomes one step, and the teardown of a
  long list is spread out. The cost is that the children's reference counts fall
  later: `isUnique` (in-place growth of a closure, `reuse=`) sees a shared cell
  for longer, and the `onCollect` of a `GCPointer` runs later. It needs a
  measurement of how often `isUnique` fails before it goes in.

## Threads

The allocator does not look at `idris2rc2_threaded`: the heap is per thread from
the start, so a program that goes multi-threaded later, or starts that way
(`multithreaded`), uses the same path. Its few global structures (the segment
list and `freeMask`, the abandoned pages) have their own lock;
`idris2rc2_spin_lock` is not it, because that one does nothing while the program
is single-threaded.

- **Own page.** `owner == tl_heap`: plain, no atomic.
- **Another thread's page.** The cell is pushed to the page's `thread_free`
  (compare-and-swap on the head). The only consumer that takes the stack is the
  page's owner (or whoever has just adopted the page), and it takes all of it with
  `atomic_exchange`, so a pusher can never see a stale head linked in (no ABA).
- **A thread ends.** The `pthread_key` of `rc2base` (`concurrency_util.c`) drops
  the thread's data in its destructor, and that destructor may run Idris code (a
  `GCPointer`'s `onCollect`) that allocates and releases cells. glibc does not fix
  the order of destructors, so the allocator's own destructor re-arms itself
  (`pthread_setspecific`) for the first rounds and gives the heap up in the last
  round but one, not the last: ThreadSanitizer finishes the thread in the last
  round and fails on a mutex taken after that. Giving the heap up:
  1. `pending` is exchanged for `POOL_DEAD`, and the entries it held are
     processed, so no thread pushes to this heap again; a pusher that finds
     `POOL_DEAD` clears the flag it set and, if the page has a new owner by now,
     queues it there;
  2. every page with a live cell gets `owner = abandonedHeap` and goes on the
     global list of its class, the others are returned;
  3. `tl_heap` goes back to the static empty heap, so an allocation after that
     takes a **new** heap. The heap structure of an ended thread is never freed
     or reused (a few hundred bytes), because another thread may still hold its
     address.
- **Adopting.** A thread that is out of pages for a class adopts an abandoned page
  of it: it sets `owner` and takes `thread_free`. A release that races with the
  change of owner is pushed to `thread_free` (any value of `owner` other than the
  releasing heap sends it there), so nothing is lost.
- **A page whose cells were all released remotely** keeps `used > 0` until it is
  collected: by its owner, by an adopter, or by the sweep a thread makes before it
  takes a new page, or by `idris2rc2_poolPurge()`.
- **The main thread** does not run key destructors, so its heap is never
  abandoned; other threads release its cells to `thread_free`.
- **A heap created after the last round** (an allocation in a destructor that
  ran late) is never abandoned: its pages stay with it.
- **`fork(2)`** is called only by `popen2`, which `exec`s at once in the child;
  nothing is done for it.
- **Reference counts are unchanged:** the plain/atomic split stays as it is
  (`hybrid-refcount.md`).

## Returning memory

- A page whose `used` falls to 0, other than the one a class is allocating from,
  goes on its heap's list of empty pages (newest first); only the owner touches
  that list. A page can be taken from there for any class.
- A heap keeps empty pages up to the larger of 64 pages (4 MiB) and 1/8 of the
  pages it holds, and starts to return only when it has a quarter more than that.
  The oldest are returned: `madvise(MADV_DONTNEED)`
  on the page, so the resident size really drops, then the page is marked free in
  its segment's `freeMask` (under the global lock). A new page is taken from the
  first segment with a free page, so the memory stays in few segments. A class's
  `direct` page is never given up by this, so a loop that allocates and releases
  in turn does not hand a page back and take it again.
- **`idris2rc2_poolPurge()`** gives back what is empty now. It empties the calling
  heap (its `direct` pages that have no live cell, and every empty page), and
  sweeps the abandoned pages. It does not touch the pages of another running
  thread (that thread is the only one allowed to). It is for tests and for
  long-running programs.
- Cells too big for the classes are `malloc`'s, which returns its own large
  blocks.
- Transparent huge pages could keep a 64 KiB `MADV_DONTNEED` from lowering the
  resident size; not measured.

## Checking it

- **Check mode, `IDRIS2RC2_POOL_CHECK`** (compile time). A released cell has its
  `rc` and `reserved` set to a pattern and the rest of its body (past the link)
  filled with `0xDD`; the allocation checks that the body is still all `0xDD`
  (a write after the release) and that the page's class is the one asked for. A
  second release of a cell, or a pointer that is not on a cell boundary of its
  page, aborts. A closure whose `filled` exceeds its `arity` aborts too: pool
  cells have no slack, where `malloc` rounds a 32-byte request up to 40 and hid an
  overrun, so here it would overwrite the next cell's header. The emitter keeps
  `idris2rc2_tailcallApplyClosure` to the last hop of a chain for this reason
  (`Emit.idr`, the comment above `applyChain`).
- **Pool off.** `IDRIS2RC2_POOL=0` (environment, read before any other
  constructor) or `-DIDRIS2RC2_NO_POOL` (compile time) make every cell a `malloc`
  block: `cellAlloc` and `cellFree` test `idris2rc2_poolOn`, a predictable branch.
  `verify.sh` sets it for its valgrind runs (`LEAK_SENSITIVE_TESTS`): a pool in
  4 MiB `mmap` segments hides every leak, double free and use after free from
  valgrind, so those tests would pass without checking anything. The same switch
  is for ASan.
- **`rc2/tests/pool/run.sh`**, which `verify.sh` runs, builds
  `poolstress.c` three ways (as it ships, in check mode, under ThreadSanitizer)
  and runs it: producers and consumers on different threads; a ring of four
  threads that all allocate and release the cells of the one before; 400
  short-lived producers whose cells one long-lived consumer releases, and 300
  threads that end with live cells (the peak number of pages in use must stay
  small: the pages of ended threads are adopted or swept); local churn in
  scrambled order; and a large
  heap built and released, after which the resident size must fall (not asked
  under ThreadSanitizer, whose shadow memory is resident). It does not cover
  page reuse across classes while stale `pending` entries exist, nor a single
  page released to by many threads at once.

## Stages, and what decides each (0, 1a, 1b, 1c and 2 are done)

| stage | content | measured against |
|---|---|---|
| 0 | `cellAlloc`/`cellFree`, the audit table above, the check for `args[filled]` writes, `verify.sh` valgrind runs with the pool off. Still `malloc`: no change of behaviour | `verify.sh` unchanged |
| 1a | segments, pages, heaps, local release, remote release, the slow path and the full list; `newConstructor`/`mkClosure` still called out of line | `base` built by `stage1` (CC fixed to `gcc`), a list `map`/`filter`, `sort`: against glibc and against mimalloc by `LD_PRELOAD`, **in the same session**. Passed: see Results |
| 1b | abandon/adopt, the thread-exit protocol, the tests for them | the concurrency tests, `tsan` |
| 1c | return to the OS, `idris2rc2_poolPurge()`, the memory test | resident size after the large-list test |
| 2 | `newConstructor` and `mkClosure` inline with a constant class and header word; batched remote release | instructions of `stage1` (callgrind), time, and the size of the executable and the build time of the compiler |
| 3 | `Integer` through `mp_set_memory_functions`; recycle at allocation, if the measurement says so | an `Integer`-heavy benchmark; how often `isUnique` fails. Measured, not done: see "Stage 3, measured" |

The gate is stage 1a, before the hard parts (1b, 1c) are written: if it does not
get near what mimalloc gives, there is little reason to carry an allocator of our
own, and bundling mimalloc as a dependency has to be weighed again. The
comparison is not exact: `LD_PRELOAD` also replaces the allocation of strings,
`Integer` and buffers, which the pool leaves to `malloc`. What an allocator of our
own can add that mimalloc cannot is the inline fast path, the single header store,
and the batched remote release; those are stage 2.

Stage 2 meets an earlier result: forcing `dup`/`drop` inline cut instructions by
7.1% and time by 5%, but built the compiler in 40 minutes instead of 10 and grew
the executable from 15 to 38 MB (`self-hosting.md`, item 7). So only the
allocation is inlined; `cellFree` and `idris2rc2_releaseReuse` (10,739 sites in
idris2-lsp, `reuse-analysis.md`) stay short out-of-line functions, and the size
of the executable and the build time are measured with it.

Stage 3's `mp_set_memory_functions` is a process-wide setting: it also governs
every `mpz` of the libraries, its functions are thread-safe by the same design,
and GMP passes the size to the release, which the pool does not need.

## Risks

- A lot of code for one pass of review: pages, heaps, abandonment and the return
  policy are each a place for a bug that shows up only under threads. Check mode,
  `tsan` and the stress tests above are part of the stages, not later, and the
  hard parts are behind the gate.
- A cell that is small by one rule and big by another would be allocated by one
  allocator and released by the other. One function decides, its callers are the
  allocation and release sites, and check mode catches a disagreement; stage 0
  makes the two lists explicit.
- The resident size can be higher than with glibc for a program whose live data
  is spread thinly over many pages (a page with one live cell stays). Pages are
  not compacted.
- Cells are 8-byte aligned, not 16: a 24-byte cell can straddle a cache line.
  Nothing relies on 16: the only pointer tag is bit 0 (`idris2rc2_is_unboxed`).

## Results (2026-11-10, stages 0 to 1c)

`base` and `prelude` of `idris2-src/libs` built by the same `stage1` (the rc2-built
compiler, compiled with `gcc`), three runs each, in seconds:

| allocator | `prelude` | `base` |
|---|---|---|
| the cell pool | 5.55 | 71.0 |
| `malloc` (`IDRIS2RC2_POOL=0`) | 6.84 | 87.3 |
| `malloc` with mimalloc preloaded | 5.97 | 75.5 |

The pool is 18.7% faster than `malloc` and 6.0% faster than mimalloc on `base`. The
same compiler built without the pool code (the state before stage 0) took 84.0 s,
so against that build the gain is 15.5%; the `POOL=0` run is slower than that build
by the class computation in `cellFree`.

List-heavy programs (stage 1a, best of three, seconds): building, mapping, filtering
and dropping a 300000-element list fifty times (`BenchListChurn`) 1.98 with the pool,
3.01 with `malloc`, 2.47 with mimalloc; `Data.List.sort` of a million `Int`s
(`BenchListSort`) 0.72, 0.86, 0.72.

Stage 2 (2026-11-10): the same `base` build, with the allocation inline, takes 69.5 s
(71.0 s before), the compiler's executable grows from 15.27 to 15.78 MB (+3%) and
its own build from 611 to 624 s (+2%). The batched remote release: 4 million cells
released by a thread other than the one that allocated them (`poolstress`) take
31 ms, against 125 ms with a compare-and-swap per cell.

What is left: nothing planned; see the next section for stage 3.

## Stage 3, measured: not worth doing

Stage 3 was to put GMP's allocations through the pool (`mp_set_memory_functions`) and
to recycle at allocation. Measured on 2026-11-10 on the code as it stands (the cell
pool of stage 2 in every run):

- **Building `libs/prelude` with the rc2-built compiler**: GMP makes 439 allocations,
  against 73.9 million in all (callgrind call counts), 0.0006%. An `Integer` that fits
  in 62 bits is an immediate and never reaches GMP.
- **An upper bound for every allocation outside the pool** (strings, `Integer`,
  arrays, buffers): the same `stage1` with mimalloc preloaded on top of the pool,
  three runs each: `base` 69.15 s against 69.00 s (-0.2%), `prelude` 5.52 s against
  5.43 s (-1.6%). A pool for strings and `Integer` cannot gain more than that.
- **Programs that do use big `Integer`s**: a loop on numbers of two or three limbs
  (about 2^70 to 2^140, three million iterations, three `Integer` operations each,
  every result a boxed `Integer` with its limb array) takes 1.51 s with the pool, 1.50 s
  with `malloc`, 1.49 s with mimalloc (which also replaces GMP's allocations). The
  time is in the GMP arithmetic; a pool for the `Integer` cell and for the limbs would
  gain at most 1%.

So the `Integer` cell and GMP stay with `malloc`. Recycling at allocation (the
candidate in "What it does for constructors and for short-lived lists") was not
measured and is not planned: the gain it aims at, a cheaper allocation and release
of a cell, is what the pool now does, and its cost (later reference counts, a later
`onCollect`) was the reason it needed a measurement first. Known limits: the structure of a heap that has ended
is never freed (a few hundred bytes; a thread that only releases cells gets one, and frees it again if no page was ever its own); a heap created after the last destructor round
is never given up; a stale entry on a heap that no longer runs delays the collection
of the cells released to a page of another heap (see "Stale entries").
