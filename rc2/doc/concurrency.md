# Concurrency (`rc2/support/rc2/`)

Implementation notes for rc2's runtime-side concurrency posture, built
in stages: first making the reference count itself safe to touch from
more than one thread, then making real OS thread spawning (`refc_fork`)
and Mutex/Condition actually work, then filling in every remaining
`System.Concurrency`-family primitive left out of that second stage
(`conditionWaitTimeout`, `getThreadId`, `setThreadData`/`getThreadData`,
`Semaphore`, `Barrier`, `Channel`) plus an rc2-specific joinable fork --
all three stages are now done, see "Status" below for exactly what's
implemented. Only one thing in this whole document adds genuinely new
Idris-level API surface: the rc2-specific joinable fork (`forkJoin`/
`join`/`JoinHandle`), which has no upstream equivalent to patch onto --
see "Design: joinable fork" below for why. Everything else, `Channel`
included (see "Design: Channel" for that one's own back-and-forth),
patches an existing upstream `System.Concurrency` declaration via
`%foreign_impl`: existing types and functions work unchanged, just now
actually backed by real threads and pthread primitives instead of a
stub. Written to let a future session (or a
future you) regain full context without re-deriving the design or
re-discovering the constraints already identified here. This document
is a *living* one, updated as later stages land.

(Japanese translation: `doc/ja/concurrency.md`, updated only on request
-- this English original is the one kept current on every edit.)

## Background

rc2's runtime (`rc2/support/rc2/`) descends from upstream RefC's own
support library, which assumes a single-threaded execution model
throughout: reference counts are plain, non-atomic integers, mutated
with ordinary `++`/`--`. rc2 inherited that assumption unmodified for
most of its history (see `TODO.md`'s former "Concurrency: unchanged
from RefC" entry, now superseded by this document).

For most of rc2's history, and still true through the atomic-refcount
step below, nothing in rc2 spawned a real OS thread: `%foreign
"C:refc_fork"` (`rc2/support/rc2/ioprims.c`, the landing point for
Idris2's `prim__fork`) was a stub that printed "Threads not implemented
in the rc2 backend!" and called `exit(0)` rather than actually forking a
thread. That changed in the real-thread-spawning step (see "Design:
real thread spawning" below) -- `refc_fork` now actually spawns a
detached `pthread`, so reference-count mutations can genuinely race
across threads, which is exactly what the atomic representation below
and the fixes in "Resolving the races unlocked by real thread spawning"
exist to make safe.

Making the refcount atomic first, ahead of `refc_fork` actually doing
anything, was deliberate groundwork: it let the *representation* be
correct before any code depended on it being correct, and turned the
later real-thread-spawning step into a precisely scoped follow-up --
this document's own punch list from that step (the three bare
decrements and the small-integer lazy-init flag, see below) became
exactly the diff the next step needed to make, rather than a second,
riskier reverse-engineering pass done under time pressure.

## Design: atomic refcount, and why these memory orders

Changed files at this step: `datatypes.h`, `memory.c`, `runtime.h`.
`memory.h`/`runtime.c` were unchanged here (see "Resolving the races
unlocked by real thread spawning" below for why that was safe at the
time, and what changed once real thread spawning landed).

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

## Design: real thread spawning (`refc_fork`)

Changed file: `ioprims.c` (`util.h` and `<pthread.h>` newly included).

`refc_fork` now runs the forked closure on a real, detached `pthread`:

- It `idris2rc2_dup`s the closure before calling `pthread_create`, then
  hands the duped pointer to a small trampoline
  (`idris2rc2_threadTrampoline`) that applies it to the erased `%World`
  token via `idris2rc2_applyClosure` and drops the result. This dup is
  not optional bookkeeping -- it fixes a genuine use-after-free found
  while testing this step: the generated `prim__fork` wrapper drops its
  own reference to the closure immediately after `refc_fork` returns
  (the ordinary "FFI call consumed its argument" convention), but the
  spawned thread keeps using the same pointer well past that point.
  Without the dup, the caller-side drop could free the closure out from
  under the still-running thread.
- The thread is `pthread_detach`'d immediately, not joined. This matches
  what's actually reachable: the only Idris-level primitive that could
  join a forked thread, `threadWait`, is Scheme-only in upstream
  `System.Concurrency.idr` and has no C-backend implementation at all --
  unreachable from rc2 (or RefC) regardless of what `refc_fork` itself
  does. A fire-and-forget detached thread is therefore not a shortcut;
  it's the only behavior any caller can currently observe.
- The returned `ThreadID` is a plain `IDRIS2RC2_Pointer` wrapping a
  heap-allocated `pthread_t`, not a dedicated tag. `ThreadID` is
  `[external]` in upstream Idris2, which rc2 marshals as CFUser (an
  unconstrained `IDRIS2RC2_Value*` identity passthrough -- see
  `Compiler.RC2.EmitUtil`'s `packCFType`/`extractValue`), so any
  correctly-shaped value works; since `threadWait` can never read it
  (see above), there's nothing that needs a dedicated representation.

## Resolving the races unlocked by real thread spawning

`refc_fork` becoming real (above) meant more than one thread could
finally run concurrently, which made three call sites in `runtime.c`
and one in `memory.c` reachable races for the first time. All four are
now fixed; this section keeps the original reasoning for why each was
safe before this step, and records what changed.

**`idris2rc2_trampoline`, `idris2rc2_tailcallApplyClosure`,
`idris2rc2_dropReuseConstructor` (`runtime.c`).** Before this step, all
three performed a bare `--`/`==` on `refCount` with no zero-reaching
check at all. This compiled and ran correctly as-is -- now that
`refCount` is `_Atomic uint16_t`, a bare `--`/`==` on it is C11's
implicit atomic compound-assignment/comparison (default
`memory_order_seq_cst`), so there was no type error and no undefined
behaviour -- but relied on a **single-threaded execution invariant**:
each only ran on the "not unique" branch, where `annotate`'s own
ownership analysis had already established the count was at least 2
going in, so a plain decrement couldn't reach zero there, true only
because nothing else could be concurrently dropping the same value at
the same time. Fixed as follows:

- `idris2rc2_trampoline`: the `isUnique(c) ? free(c) : --c->header.refCount`
  branch is now a single unconditional
  `atomic_fetch_sub_explicit(..., memory_order_release)`, freeing `c`
  only when that returns `1` (guarded by an
  `atomic_thread_fence(memory_order_acquire)` first) -- the same
  release-decrement-plus-acquire-fence-on-zero pattern
  `idris2rc2_drop` already used. Only the closure shell itself is freed
  here, not a full `idris2rc2_drop` teardown, since `dispatchClosure`
  had already consumed ownership of the args; re-dropping them would
  double-drop.
- `idris2rc2_tailcallApplyClosure`: its args are `dup`'d into the new
  closure, not stolen, so `c`'s own reference is released normally --
  the bare `--c->header.refCount;` is replaced with an ordinary
  `idris2rc2_drop((IDRIS2RC2_Value *)c)` call.
- `idris2rc2_dropReuseConstructor`: same release-decrement-plus-
  acquire-fence-on-zero swap as `idris2rc2_trampoline`, though here
  it's belt-and-suspenders rather than a real race fix -- this function
  is only ever called on a value whose uniqueness `idris2rc2_isUnique`
  has already established statically (see `reuse-analysis.md`), so no
  other thread can concurrently touch this particular `refCount`
  regardless; the change just makes the memory access atomic like every
  other `refCount` op, instead of relying on a separate argument for
  why a plain access happens to be safe.

The one-line "Why not" comment `runtime.h` used to carry directly above
`idris2rc2_isUnique`, documenting this constraint, has been removed now
that it no longer applies.

**`idris2rc2_getSmallInteger`'s lazy-init flag (`memory.c`).** Before
this step, `idris2rc2_smallIntegerInit` was a plain, non-atomic `static
bool` driving a classic unsynchronized check-then-set-then-init-loop --
safe only because no two threads could ever call it concurrently, and
under real concurrent first calls could otherwise run the
initialization loop more than once, or let one thread observe a
partially-initialized cache. Fixed by replacing the flag with a
`pthread_once_t` / `idris2rc2_initSmallInteger` pair driven through
`pthread_once`, which guarantees the init loop runs exactly once and
that every caller, regardless of thread, only ever observes the cache
fully initialized.

## Design: Mutex/Condition

Upstream Idris2's `System.Concurrency` module declares `Mutex`,
`Condition`, `makeMutex`, `mutexAcquire`, `mutexRelease`,
`makeCondition`, `conditionWait`, `conditionSignal`, and
`conditionBroadcast` as `%foreign` primitives, but ships only a
Scheme-backend implementation -- every C backend, RefC included, has
never been able to use them.

Two alternative designs were considered before settling on the one
implemented:

- **Wrap the pthread objects in `GCAnyPtr`** (rc2's existing
  arbitrary-payload-plus-finalizer pointer type). Rejected: `GCAnyPtr`
  runs its finalizer through the ordinary `PrimIO ()` closure-apply
  path -- i.e. it costs a full closure application on every teardown --
  for a payload (a `pthread_mutex_t`/`pthread_cond_t`) that only ever
  needs a fixed, known-in-advance C destructor call.
- **Introduce new `data` types on the Idris side, with their own FFI
  surface**, rather than backing the existing `Mutex`/`Condition`.
  Rejected: it would force every caller to depend on an rc2-specific
  module instead of `System.Concurrency`, breaking portability of code
  written against the upstream API for no benefit -- nothing about
  `Mutex`/`Condition`'s existing signature needed to change.

What was implemented instead:

- **`%foreign_impl`** (`libs/rc2base/src/System/Concurrency/RC2.idr`),
  an existing Idris2 directive (see
  `idris2-src/docs/source/ffi/ffi.rst`) that attaches a concrete
  `%foreign` implementation to an *existing* primitive declaration from
  another module, without touching that module (`idris2-src` is a
  read-only upstream clone, never edited). Callers add one import,
  `System.Concurrency.RC2`, alongside the ordinary `System.Concurrency`
  -- `Mutex`, `Condition`, `makeMutex`, and the rest of the upstream API
  work completely unchanged from there; no new types or functions are
  introduced anywhere.
- **Two new native `IDRIS2RC2_Value` tags**,
  `IDRIS2RC2_TAG_MUTEX`/`IDRIS2RC2_TAG_CONDITION` (`datatypes.h`), each
  a single-allocation struct with a `pthread_mutex_t`/`pthread_cond_t`
  embedded directly in the header-prefixed value (no extra pointer
  indirection). This is what upstream's `Mutex`/`Condition` being
  declared `[external]` licenses: rc2 marshals `[external]` as CFUser,
  an unconstrained `IDRIS2RC2_Value*` identity passthrough (see
  `Compiler.RC2.EmitUtil`'s `packCFType`/`extractValue`), so any
  correctly-tagged value is a valid one -- a dedicated tag with the
  pthread object inline is the simplest shape that satisfies that, and
  it lets `idris2rc2_teardown` (`memory.c`) call
  `pthread_mutex_destroy`/`pthread_cond_destroy` automatically once the
  refcount reaches zero, the same way `IDRIS2RC2_TAG_BUFFER` already
  frees its buffer -- no explicit `free` primitive needed on the Idris
  side.
- The actual `pthread_mutex_*`/`pthread_cond_*` calls live in
  `libs/rc2base/support/c/concurrency_util.c`, wired up as the
  `%foreign_impl` targets (`idris2rc2_mutex_make`,
  `idris2rc2_mutex_acquire`, `idris2rc2_mutex_release`,
  `idris2rc2_condition_make`, `idris2rc2_condition_wait`,
  `idris2rc2_condition_signal`, `idris2rc2_condition_broadcast`).

## Design: Semaphore and Barrier

Same pattern as Mutex/Condition above, and for the same reason: upstream
`System.Concurrency` declares `Semaphore`/`makeSemaphore`/
`semaphorePost`/`semaphoreWait` and `Barrier`/`makeBarrier`/
`barrierWait` as `%foreign` primitives with only a Scheme
implementation. `%foreign_impl` (`libs/rc2base/src/System/Concurrency/
RC2.idr`) attaches C implementations onto those existing declarations
without touching upstream. Two new native tags,
`IDRIS2RC2_TAG_SEMAPHORE`/`IDRIS2RC2_TAG_BARRIER` (`datatypes.h`), embed
a `sem_t`/`pthread_barrier_t` directly in the header-prefixed value,
the same single-allocation shape `IDRIS2RC2_TAG_MUTEX`/`_CONDITION`
already use; `idris2rc2_teardown` (`memory.c`) calls `sem_destroy`/
`pthread_barrier_destroy` once the refcount reaches zero, so there's no
explicit free primitive on the Idris side. The actual pthread/semaphore
calls (`idris2rc2_semaphore_make`/`_post`/`_wait`,
`idris2rc2_barrier_make`/`_wait`) live in
`libs/rc2base/support/c/concurrency_util.c`.

`conditionWaitTimeout` and `getThreadId` are `%foreign_impl` patches
too, but need no new tag: `idris2rc2_condition_wait_timeout` wraps
`pthread_cond_timedwait` against a `CLOCK_REALTIME`-based absolute
deadline computed from the caller's microsecond count;
`idris2rc2_get_thread_id` wraps Linux's `gettid()` (needs
`_GNU_SOURCE`).

`setThreadData`/`getThreadData` are backed by a single
`_Thread_local IDRIS2RC2_Value *`, one slot per OS thread.
`idris2rc2_set_thread_data` drops the slot's previous value before
overwriting it -- ordinary refcount discipline, not a new mechanism --
and `idris2rc2_get_thread_data` `dup`s before returning, since the
caller receives its own fresh reference while the thread-local slot
keeps its own.

## Design: joinable fork (`forkJoin`/`join`, `JoinHandle`)

Upstream `System.Concurrency.idr` has no joinable-fork equivalent to
patch: its `ThreadID`/`threadWait` can't join anything from any C
backend, `threadWait` being Scheme-only, exactly the unreachability
"Design: real thread spawning" above already relies on to justify
`refc_fork` detaching unconditionally. So `forkJoin`/`join`/
`JoinHandle` are a fresh `%foreign` declaration (`libs/rc2base/src/
System/Concurrency/RC2.idr`), not a `%foreign_impl` patch -- this is
genuinely new Idris-level API surface, absent from upstream entirely.

A new tag, `IDRIS2RC2_TAG_JOINHANDLE` (`datatypes.h`), holds the raw
`pthread_t` plus a `joined : bool` flag. `idris2rc2_fork_join`
(`concurrency_util.c`) mirrors `idris2rc2_fork`'s own trampoline
(`ioprims.c`) -- including `dup`ing the closure before `pthread_create`
for the same use-after-free reason -- but spawns the thread *not*
detached, since it may still need to be joined; `idris2rc2_join`
`pthread_join`s and sets `joined = true`.

The `joined` flag is what makes `idris2rc2_teardown`'s
`IDRIS2RC2_TAG_JOINHANDLE` case correct either way a handle can be
dropped: if it's dropped without ever being joined, teardown
`pthread_detach`s it so the underlying thread doesn't become a zombie;
if it *was* joined, teardown does nothing further, because
`pthread_join` already reaped the thread and its `pthread_t` is no
longer a valid identifier -- touching it again (a second detach or
join) is undefined behavior. `join` is documented as callable at most
once per handle, the same lack of a type-enforced uniqueness guarantee
upstream's own `Mutex`/`Condition` API already has; nothing beyond that
documentation stops a caller from calling it twice.

## Design: Channel

Channel was originally the one primitive in this stage that couldn't be
attached via `%foreign_impl` at all: `channelGetNonBlocking`/
`channelGetWithTimeout` return `Maybe a`, and building an arbitrary
compilation's `Just` from generic runtime C looked unsafe in general
(see TODO.md's "Dropped: unwrapping `Just x` to a bare `x`" entry for
the full investigation) -- only `Nothing`'s NULL representation is a
fixed, program-independent convention. The first version of Channel
therefore avoided `Maybe` construction entirely, implemented in
ordinary Idris (`MkChannel (IORef (List a)) Mutex Condition`) on top of
the already-verified Mutex/Condition/IORef primitives, with its own
fresh `Channel` type `%hide`-shadowing upstream's.

That's since been revisited and replaced with a `%foreign_impl`-backed
implementation, patching `System.Concurrency`'s own `prim__makeChannel`/
`prim__channelGet`/`prim__channelGetNonBlocking`/
`prim__channelGetWithTimeout`/`prim__channelPut`, the same way as every
other primitive in this document. This is **not** the general "unwrap
`Just x` to `x`" idea that TODO.md records as dropped for being unsound
-- that one tried to *elide* a Constructor allocation for an arbitrary
payload type, which collides with `Nothing` whenever the payload is
itself NULL-representable (`Just []`, `Just ()`, `Just Nothing`, ...).
What `idris2rc2_channel_get_non_blocking`/`_get_with_timeout`
(`libs/rc2base/support/c/concurrency_util.c`) do instead is narrower and
sound: they always *build* a real `IDRIS2RC2_Constructor` for `Just`
(`idris2rc2_newConstructor(1, 1)`) or return `NULL` for `Nothing`, never
eliding one. This only works because `Prelude.Maybe`'s own tag
assignment is a fixed, program-independent fact (confirmed empirically:
an ordinary `Just x` compiles to `idris2rc2_newConstructor(1, 1)`, and
`ConstFold`'s own staged-static `Just []` uses the same tag/arity) --
**a documented limitation**, not a general technique: it relies on
`Prelude.Maybe` being one fixed, versioned library type shared by every
rc2 program, not a per-program user-defined ADT, and would break if a
future Idris2 ever reordered `Nothing`/`Just`'s own declaration.

`Channel a` is backed by a new native tag, `IDRIS2RC2_TAG_CHANNEL`
(`datatypes.h`): an embedded `pthread_mutex_t`/`pthread_cond_t` guarding
a singly-linked FIFO queue of owned `IDRIS2RC2_Value*` nodes.
`channelPut` appends a node and signals (`idris2rc2_dup`ing the value
first -- the generated FFI wrapper drops its own reference to every
argument right after the call returns, the same convention
`idris2rc2_fork`/`idris2rc2_fork_join`'s own `dup` already documents,
and the node here outlives the call); `channelGet` blocks on the
condition variable while the queue is empty, then pops; the
non-blocking/timeout variants pop-or-`NULL` and pop-or-wait-once-or-
`NULL` respectively (the timeout version keeping the earlier version's
"single wait covers the whole budget, no exact deadline tracking"
simplicity). `idris2rc2_teardown`'s CHANNEL case destroys the mutex/cond
and walks any still-queued nodes, dropping each stored value before
freeing the node -- a channel dropped with pending, never-received
messages must not leak them.

Because Channel is patched onto upstream's own declarations now, the
earlier version's `%hide` workaround and its separate, non-reusable
`Channel` type are both gone -- callers just `import System.Concurrency`
`import System.Concurrency.RC2` and use `System.Concurrency`'s own
`Channel`/`makeChannel`/... unchanged, same as every other primitive in
this document.

## Finding: `%foreign` type witnesses are not erased

Discovered while implementing `setThreadData`/`getThreadData`/
`forkJoin`/`join`: a `%foreign` primitive's polymorphic type parameter
-- an implicit `{a : Type}`, or the witness rc2's own FFI convention
supplies whenever `a` appears in a return type -- is **not** erased by
rc2's codegen. Confirmed empirically, by building and reading the
actual generated C, not by inspecting the compiler's erasure logic
directly. All four affected C functions (`idris2rc2_set_thread_data`,
`idris2rc2_get_thread_data`, `idris2rc2_fork_join`, `idris2rc2_join`,
`concurrency_util.c`/`.h`) therefore take a leading
`IDRIS2RC2_Value *typeWitness` parameter that's received and
immediately ignored. Worth re-checking the generated C for this again
before assuming erasure on any future primitive whose signature
mentions a bare polymorphic `a`, rather than trusting that assumption
from first principles.

## Status

**Reference count made atomic: done and verified.** `datatypes.h`,
`memory.c`, `runtime.h` as described above. Verified via
`rc2/tests/verify.sh` (refc-suite 19/19 PASS, smoke tests 32/32 PASS,
`valgrind` reporting zero errors) and `rc2/tests/bench.sh` (no measured
performance regression from the `relaxed`/`release`/`acquire`
choices above); `-Wall` build clean.

**Real thread spawning (`refc_fork`) and Mutex/Condition: done and
verified.** `refc_fork` now spawns a real detached `pthread` (see
"Design: real thread spawning" above), which made all four races
flagged by the atomic-refcount step reachable for the first time --
all four are now fixed (see "Resolving the races unlocked by real
thread spawning" above). `Mutex`/`Condition` are usable from rc2 via
`System.Concurrency.RC2`'s `%foreign_impl` (see "Design: Mutex/
Condition" above). Verified via `rc2/tests/verify.sh` (refc-suite
19/19 PASS, smoke tests 32/32 PASS, `valgrind` reporting zero errors)
and `libs/rc2base/tests/verify.sh` (`TestText`/`TestTextTree`/
`TestConcurrency` all PASS -- the new `TestConcurrency.idr` exercises
`fork` + `Mutex` + `Condition` together: multiple threads incrementing
a shared counter and waiting on a condition), plus
`valgrind --fair-sched=yes` and `helgrind` reporting no data races, and
`rc2/tests/bench.sh` showing no measured performance regression.

**Remaining `System.Concurrency`-family primitives, joinable fork, and
Channel: done and verified.** `conditionWaitTimeout`, `getThreadId`,
`setThreadData`/`getThreadData`, `Semaphore`, `Barrier`, and (as of a
later revisit, see "Design: Channel" above) `Channel` itself are all
usable from rc2 the same way `Mutex`/`Condition` are -- `%foreign_impl`
onto upstream's existing prim__ declarations. An rc2-specific joinable
fork (`forkJoin`/`join`/`JoinHandle`) fills the one gap upstream itself
can't cover on any C backend (see "Design: joinable fork" above).
Verified via `rc2/tests/verify.sh` (56 passed, 2 known pre-existing, 0
failed) and `libs/rc2base/tests/verify.sh` (`TestConcurrency.idr`
extended to exercise every new primitive, all PASS), plus
`valgrind --fair-sched=yes` and `helgrind` reporting no new errors at
the time. Both loose ends mentioned in an earlier revision of this
paragraph are now resolved: the `List.(++)`-on-repeated-`IORef`-append
leak turned out to share a root cause with `Compiler.RC2.RC`'s own
`RExtPrim` ownership-annotation gap (fixed, see
`doc/c-struct-support.md`'s own addendum), and `idris2rc2_fork`'s own
`ThreadID` malloc (it wrapped a heap-allocated `pthread_t*` in a generic
`IDRIS2RC2_Pointer`, whose teardown deliberately never frees an
externally-owned payload -- wrong for a pointer rc2 itself allocated)
is fixed by giving `ThreadID` its own dedicated tag
(`IDRIS2RC2_TAG_THREADID`, `datatypes.h`) that embeds the `pthread_t`
directly, the same single-allocation idiom already used for
`Mutex`/`Condition`/`Semaphore`/`Barrier`/`JoinHandle`. Channel's own revisit additionally
fixed a genuine use-after-free found while testing it: `channelPut`'s
generated FFI wrapper drops its own reference to the value right after
the call returns, but the queued node outlives that call -- the same
"FFI call consumes its argument" convention `idris2rc2_fork`'s own `dup`
already documents, missed here until a concurrent `Integer`-valued
`Channel` test crashed inside `libgmp`.

## Outlook

Every item this document's own "Not yet implemented" list (and
`TODO.md`'s Concurrency section) used to name is now implemented. Two
things worth keeping in mind for future work here, neither blocking
anything today:

- rc2's `Mutex`/`Condition`/`Semaphore`/`Barrier`/`JoinHandle` are all
  backed by pthread objects with exactly the shape upstream's
  `[external]` marshaling licenses, but nothing about that shape is
  visible to, or reusable by, a different backend -- callers only ever
  see the opaque upstream type, so this isn't a portability constraint
  in practice, just worth remembering if a future backend-comparison
  pass ever inspects concrete representations.
- `channelGetWithTimeout`'s single-wait budget (see "Design: Channel"
  above) is deliberately simple rather than exact deadline tracking.
  Revisit only if a caller actually needs precise deadline semantics;
  nothing found during this stage's own testing needed it.
