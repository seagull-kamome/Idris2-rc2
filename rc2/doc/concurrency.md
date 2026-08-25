# Concurrency (`rc2/support/rc2/`)

Implementation notes for rc2's runtime-side concurrency posture --
starting with making the reference count itself safe to touch from more
than one thread. This is the *first* step of a multi-step effort (real
OS thread spawning and the primitives it needs are separate, later
steps, not yet started -- see "Status" below); no Idris-level API
changes are involved anywhere in this step. Written to let a future
session (or a future you) regain full context without re-deriving the
design or re-discovering the constraints already identified here. This
document is a *living* one, updated as later stages land -- see
"Status" below for exactly what's implemented today versus still
planned.

(Japanese translation: `doc/ja/concurrency.md`, updated only on request
-- this English original is the one kept current on every edit.)

## Background

rc2's runtime (`rc2/support/rc2/`) descends from upstream RefC's own
support library, which assumes a single-threaded execution model
throughout: reference counts are plain, non-atomic integers, mutated
with ordinary `++`/`--`. rc2 inherited that assumption unmodified for
most of its history (see `TODO.md`'s former "Concurrency: unchanged
from RefC" entry, now superseded by this document).

Nothing in rc2 currently spawns a real OS thread. `%foreign
"C:refc_fork"` (`rc2/support/rc2/ioprims.c`, the landing point for
Idris2's `prim__fork`) is a stub: it prints "Threads not implemented in
the rc2 backend!" and calls `exit(0)` rather than actually forking a
thread. So today, every reference-count mutation still happens on a
single thread, in practice, regardless of what the header type or
increment/decrement instructions themselves say.

Making the refcount atomic now, ahead of `refc_fork` actually doing
anything, is deliberate groundwork: it lets the *representation* be
correct before any code depends on it being correct, and avoids a
second, riskier pass over the same handful of files later, done under
time pressure once thread spawning is being implemented.

## Design: atomic refcount, and why these memory orders

Changed files: `datatypes.h`, `memory.c`, `runtime.h`.
`memory.h`/`runtime.c` are unchanged (see "Out of scope" below for why
that's safe today).

- **`datatypes.h`**: `IDRIS2RC2_Header.refCount` changed from
  `uint16_t` to `_Atomic uint16_t` (`<stdatomic.h>` now included). The
  header's own top-of-file comment, which used to describe "a
  non-atomic reference count," is updated to match.
- **`memory.c`, `idris2rc2_dup`**: the increment is now
  `atomic_fetch_add_explicit(&v->header.refCount, 1,
  memory_order_relaxed)`. `relaxed` is enough here because incrementing
  a count that's already known to be live (the caller already holds a
  reference) doesn't need to publish or observe any other memory --
  it's the *decrement that reaches zero* that has to synchronize with
  every prior reader, not the increment.
- **`memory.c`, `idris2rc2_drop`**: the decrement is now
  `atomic_fetch_sub_explicit(&v->header.refCount, 1,
  memory_order_release)`. Its return value (the count *before* the
  decrement) is checked for `1`; only then does an
  `atomic_thread_fence(memory_order_acquire)` run, immediately before
  calling `idris2rc2_teardown`. This is the standard release-decrement
  +  acquire-fence-on-zero pattern: the `release` on every decrement
  ensures each thread's own prior writes to the pointee (and its own
  drop of its reference) are visible to whichever thread performs the
  *last* decrement; the `acquire` fence, paid only on the thread that
  actually observes the count hit zero, ensures that thread sees every
  other thread's release before it starts tearing the value down.
  Paying the acquire fence unconditionally on every drop (instead of
  only the teardown path) would be correct too, just needlessly
  expensive on the overwhelmingly common non-final-drop case.
  The immortal check (`refCount == IDRIS2RC2_REFCOUNT_MAX`) right above
  the decrement is left as a plain, non-atomic comparison -- safe
  because a value that has reached immortal status never has its
  `refCount` written again by anything (see `idris2rc2_dup`'s own
  `!= IDRIS2RC2_REFCOUNT_MAX` guard and the small-integer-cache
  initialization in `idris2rc2_getSmallInteger`), so there is no write
  for a concurrent reader of that field to race with.
- **`runtime.h`, `idris2rc2_isUnique`**: now
  `atomic_load_explicit(&(x)->header.refCount, memory_order_acquire) ==
  1`. `acquire` is required, not just convenience: observing `refCount
  == 1` is what licenses in-place mutation (the "this thread is
  provably the sole owner" argument constructor-reuse and friends rely
  on), so that observation has to happen-after whichever other thread's
  `release`-decrement most recently brought the count down to 1 --
  otherwise this thread could start mutating a value whose
  last-known-shared state hasn't actually finished propagating yet.
  Left as a macro rather than a typed `static inline` function
  deliberately, so it stays generic over *any* struct type starting
  with an `IDRIS2RC2_Header header` field (matching every call site's
  own concrete pointer type, e.g. `IDRIS2RC2_Constructor *`), the same
  reasoning the macro already had before this change.

## Out of scope / known limitations

Three call sites in `runtime.c` -- `idris2rc2_trampoline`,
`idris2rc2_tailcallApplyClosure`, and `idris2rc2_dropReuseConstructor`
-- still perform a bare `--`/`==` on `refCount` with no zero-reaching
check at all, and are **unchanged** by this step. This compiles and
runs correctly as-is: now that `refCount` is `_Atomic uint16_t`, a bare
`--`/`==` on it is C11's implicit atomic compound-assignment/comparison
(default `memory_order_seq_cst`), so there's no type error and no
undefined behaviour. What these three sites still rely on, unchanged,
is a **single-threaded execution invariant**: each only runs on the
"not unique" branch, where `annotate`'s own ownership analysis has
already established the count was at least 2 going in, so a plain
decrement can't reach zero there -- true only because nothing else can
be concurrently dropping the same value at the same time. This is
documented directly above `idris2rc2_isUnique`'s own definition in
`runtime.h` (a one-line "Why not" comment) so it's visible at the
exact place a future reader would otherwise assume the whole refcount
story is already thread-safe.

This is unreachable today -- `refc_fork` is a stub, no real OS thread
ever runs concurrently with another -- but it is **not** correct once
real thread spawning lands, and must be revisited at that point,
either by giving these three sites the same
release-decrement-plus-acquire-fence-on-zero treatment `idris2rc2_drop`
now has, or by some other argument that re-establishes why a bare
decrement there still can't reach zero under real concurrency.

Separately, and also unaddressed by this step:
`idris2rc2_getSmallInteger`'s (`memory.c`) lazy-initialization flag
`idris2rc2_smallIntegerInit` (a plain, non-atomic `static bool`) is a
classic unsynchronized check-then-set-then-init-loop. Under real
concurrent first calls from more than one thread, this can run the
initialization loop more than once, or let one thread observe a
partially-initialized cache. Also unreachable today for the same
reason as above, and also needs revisiting (e.g. `pthread_once`, an
atomic flag with acquire/release, or eager static initialization)
once real thread spawning lands.

## Status

**Reference count made atomic: done and verified.** `datatypes.h`,
`memory.c`, `runtime.h` as described above. Verified via
`rc2/tests/verify.sh` (refc-suite 19/19 PASS, smoke tests 32/32 PASS,
`valgrind` reporting zero errors) and `rc2/tests/bench.sh` (no measured
performance regression from the `relaxed`/`release`/`acquire`
choices above); `-Wall` build clean.

**Real thread spawning (`refc_fork` actually forking an OS thread, plus
whatever Mutex/Condition-variable primitives Idris2's own concurrency
API needs behind it): not started.** Until this lands, the three bare
decrements and the small-integer lazy-init race described above remain
correct only by virtue of `refc_fork` being an unreachable stub -- both
are the concrete punch list for whoever picks this up next.
