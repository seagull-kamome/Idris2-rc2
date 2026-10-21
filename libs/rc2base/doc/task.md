# `Control.Task`: cooperative tasks on epoll

Status: milestone 1 is implemented (`Control.Task`, `Control.Task.Source`,
`Control.Task.Epoll`, `Control.Task.Scheduler`; test `TestTask`); milestones 2
and 3 are design. Where the code differs from a first sketch below it says so.

## Motivation

A program that waits for several things at once (a terminal and a socket
and a timer; a server with many connections) needs more than one logical
thread of control, and it does not want an OS thread for each. The `Task`
monad describes such logical threads as ordinary monadic code; a scheduler
runs many of them on one thread, and later on a few.

The model is that of [idris2-coop](https://github.com/buzden/idris2-coop)
("concurrency without parallelism"): a computation is a *data structure*
built by `>>=`, `zip`, `race` and `spawn`, and an interpreter turns it into
steps. What differs:

| | coop | `Control.Task` |
|---|---|---|
| substrate | any monad `m` (`Coop m a`) | `IO` (`Task a`) |
| waiting | `sleepTill` of a model or wall clock | any asynchronous operation (`Async`): `epoll` readiness and timers first, `io_uring` and others later |
| join of `zip` | `believe_me` on a pair kept in a map | two `IORef`s, typed |
| cancel by `race` | removes events of the race's syncs | a scope per race, with cleanups |
| threads | none | one scheduler thread first, then N:M (milestone 3) |

`Task` is fixed to `IO` because the scheduler uses `epoll`, `IORef`s and later
threads, which an arbitrary `m` cannot give. Letting the substrate be any
`HasIO m` (a `TaskT m`, with `Task` as `TaskT IO`) is wanted later; nothing in
the design below should stand in its way: the effects of a task are only
`Point` (an `IO` action) and the constructors, never a use of `IO` that the
type of the scheduler has to see.

## The data type

```idris
data Task : Type -> Type where
  Point  : IO a -> Task a                        -- an action, run to completion (on a worker in parallel mode)
  Pinned : IO a -> Task a                        -- the same, always on the thread of the scheduler
  Seq    : Task a -> (a -> Task b) -> Task b     -- >>=
  Both   : Task a -> Task b -> Task (a, b)       -- zip: run together, wait for both
  Race   : Task a -> Task a -> Task a            -- the first to finish wins, the other is cancelled
  Spawn  : Task () -> Task ()                    -- run alongside the continuation
  Async  : (Env -> Completion a -> IO Cancel) -> Task a         -- start an operation and wait for it
  Empty  : Task a                                -- never finishes

Completion a = a -> IO ()      -- tell the scheduler the operation is done
data Cancel = MkCancel (IO ())   -- give the operation up (a type of its own, not `IO ()`)
```

`Env` is what the scheduler offers: `now`, `addTimer`, `watchFd` and `post` (run an
action on the scheduler's thread; the one function any thread may call). `Cancel`
is a type of its own, so that `IO Cancel` is an action that returns a value; see
`rc2/doc/world-arity-raising.md`, "Soundness", for what went wrong when it was a
bare `IO ()`.

`Async` is the one primitive for *waiting*. The function starts an operation
(registers a descriptor, queues a request, sets a timer) and returns at once;
later, when the operation is done, something calls the `Completion` with the
result, and the task goes on with it. The returned `Cancel` is run if the task's
scope is cancelled before that, and must make the operation harmless (take the
descriptor out of the set, ask the kernel to cancel the request, drop the
timer); a `Completion` called after a cancel does nothing. Nothing in `Task`
knows `epoll`: a readiness API and a completion API (`io_uring`, a thread pool
that does blocking calls, a library with callbacks) all look like this.

What waits are ordinary functions on top of `Async`:

```idris
sleepFor, sleepTill  : ... -> Task ()                 -- a timer of the scheduler
awaitReadable, awaitWritable : FileDesc -> Task Ready  -- the readiness of the scheduler's epoll source
-- in other modules (Control.Task.Uring):
uringRead : FileDesc -> Buffer -> Bits32 -> Bits64 -> Task (Either Errno Nat)
```

`Ready` tells which of `EPOLLIN`, `EPOLLOUT`, `EPOLLERR`, `EPOLLHUP` came (an
error or hang-up wakes the waiter too). `Monad`, `Applicative` (sequential, as
in coop: `<*>` is `>>=`), `HasIO` (`liftIO = Point`) and `Alternative`
(`<|>` = `Race`) are implemented. The parallel `Applicative` is a named
implementation, `Concurrent`, as in coop, because `a *> b` must mean "a, then b".

Other functions: `both` (`Both`), `race : Task a -> Task b -> Task (Either a b)`,
`spawn`, `yield`, `forever`.

A `Point` runs to completion on the scheduler's thread: a blocking call in it
blocks every task. Use non-blocking descriptors and `Async` for waiting.

## Waiting for a task: promises

`spawn` starts a task and goes on; it gives no way to wait for it. `fork` does:

```idris
fork      : Task a -> Task (Promise a)    -- start beside the rest; the box for its result
wait      : Promise a -> Task a           -- until the result is in (at once if it is)
waitMaybe : Promise a -> Task (Maybe a)   -- Nothing if the task was given up
peek      : Promise a -> Task (Maybe a)   -- the result if it is there
```

Any number of tasks may wait for one promise; each gets the result. A waiter
that is given up (it lost a `race`) leaves the list of waiters. If the forked
task is given up before it ends (its scope was cancelled, by a `race` it lost
or `cancelTask`), the promise is *abandoned*: `waitMaybe` answers `Nothing` and
`wait` never ends, as `Empty` (a `race` with a timer is the way out). This is
done with a sentinel task in the scope of the producer: an `Async` that ends
when the result is put in and abandons the promise in its `Cancel`.

The state of a promise is plain `IORef`s, and every operation on it is pinned to
the thread of the scheduler (`Pinned`), so it is safe in parallel mode too.

## Semantics

- **`Seq`** runs the left side, then the continuation. A left-nested chain is
  reassociated (`Seq (Seq a f) g` becomes `Seq a (f >=> g)`) when it is
  interpreted, so `forever` and long binds do not grow the stack.
- **`Both l r`** starts `l` and `r` as two tasks that share a *join cell*: two
  `IORef (Maybe _)`. The one that finishes second finds the other's result,
  and schedules the continuation with the pair.
- **`Race l r`** opens a new *scope* below the current one and starts `l` and
  `r` in it. The first to finish cancels the scope, which cancels everything
  that runs in it, including what they spawned and the races inside them, and
  then the continuation goes on in the parent scope. `Empty` as one side makes
  the race the other side.
- **`Spawn t`** starts `t` in the current scope and goes on at once. `t` goes
  on after the continuation finished, until the scope it belongs to is
  cancelled. (The root scope is never cancelled.)
- **Cancelling a scope** sets its flag and runs its *cleanups*. A task in the
  run queue of a cancelled scope is dropped when it is taken. An `Async`
  puts its `Cancel` in its scope, so the operation is given up (for the epoll
  source: the waiter leaves the table and the descriptor is `epoll_ctl DEL`ed
  when it was the last) and a cancelled wait costs nothing afterwards. A `Point`
  that has started is never interrupted.
- **Fairness.** A task is put at the back of the run queue after each `Point`,
  so a loop of actions cannot starve the others. (A step budget per turn is the
  first thing to try if this costs too much.)

## The scheduler and its sources

The scheduler is the run queue, the scopes, the timers and a set of
*sources*. A source is whatever reports that operations are done:

```idris
record Source where
  constructor MkSource
  pollFd : FileDesc     -- readable when completions are waiting
  drain  : IO ()        -- reap them without blocking, calling their Completions
```

The `epoll` of descriptor readiness is the first source and every scheduler
has it (`awaitReadable` needs no handle). An `io_uring` ring is another: the ring
descriptor is readable when completion entries are waiting, and `drain` reaps
them and calls the `Completion` kept under each entry's `user_data`. Both are
descriptors that can be waited for, so the scheduler waits for them all with
a *master* `epoll` in which each `pollFd` is registered, and does not care what
is behind them. A source that cannot give a descriptor (a library with its own
thread) calls its `Completion` from that thread, which puts the continuation
in the *inbox* of the scheduler (a queue under a lock, with an `eventfd` that is
one more `pollFd`) instead of the run queue: that is the one rule about
threads, and it is what milestone 3 needs anyway.

```idris
record Scheduler where
  runQueue : Queue (Scope, Task ())                 -- ready
  timers   : IORef (SortedMap Time (Queue Timer))   -- by deadline
  master   : EPoll                                  -- the pollFds of the sources
  sources  : IORef (List Source)
  inbox    : Inbox                                  -- completions from other threads
```

One turn:

1. run the ready tasks until the run queue is empty (new ones that they
   make are run too, round robin);
2. work out the timeout: `0` if something is ready, else the time to the
   earliest timer, else `-1` (forever) if some operation is pending, and finish
   if there is nothing at all;
3. wait in the master `epoll`; `drain` the sources whose `pollFd` is ready and
   the inbox (their completions put continuations in the run queue);
4. move the timers whose deadline has passed to the run queue.

Timers are kept in the scheduler (a map by deadline, with `CLOCK_MONOTONIC`
time) and become the timeout of the wait; no `timerfd` is created, so a
thousand sleeping tasks use no descriptors. The resolution is a millisecond;
the timeout is rounded up so that a wait never wakes early. (A source with
timeouts of its own, as `io_uring` has, is not needed for this.)

The epoll source keeps a table of waiters by descriptor. The registration is
level-triggered and the waiters are one-shot: when a descriptor is ready the
waiters whose events match are woken and removed, and the mask is set to what
the rest want (`epollMod`) or the descriptor is taken out (`epollDel`).

An operation that needs a resource of its own and a source for it (an `io_uring`
ring) does not have to be told to the scheduler beforehand. Two functions of the
`Env` an `Async` is given do that, and neither knows what the resource is:

```idris
env.slot      : (key : String) -> IO (Either Errno (a, IO ())) -> IO (Either Errno a)
env.addSource : Source -> IO (Either Errno Cancel)
```

`slot` is the one value this scheduler keeps under `key`. The first call makes it
with the action (which also gives the action that releases it); later calls
get the same value. The releases run when the scheduler is closed, the last made
first. `addSource` adds a source and the `Cancel` it returns takes it out again.
Both are for the thread of the scheduler, which is where an `Async` starts. The
first operation on a ring makes the ring with `slot`, registers its source with
`addSource`, and an unused ring is never made.

The pieces are public, so that another loop can drive the scheduler:

```idris
newScheduler : IO (Either Errno Scheduler)
addSource    : Scheduler -> Source -> IO (Either Errno ())   -- register a source (a ring, ...)
submit       : Scheduler -> Task () -> IO ()          -- start a task (in the root scope)
pollFd       : Scheduler -> FileDesc                  -- the master epoll, readable when a turn has work
turn         : Scheduler -> (timeoutMs : Int32) -> IO Bool   -- run ready tasks, wait at most the timeout once; False when nothing is left
runTask      : Task a -> IO (Maybe a)                 -- new scheduler, submit, turn until nothing is left
```

`runTask` gives `Nothing` if the root task never finished (it was `Empty`, or
waits for something that cannot happen: nothing is left to run). It returns when
no task remains, spawned ones included, as coop does.

## Writing an operation of your own

All of them are `Async` underneath; which way to write one depends on what is
behind it.

1. **A descriptor `epoll` can wait for** (socket, pipe, pty; a database client
   with a non-blocking API and a descriptor, as `libpq` has in `PQsocket`).
   Make it non-blocking and write the usual loop in `Task`: try, and on `EAGAIN`
   `awaitReadable`/`awaitWritable`, then try again. No `Async` is written by hand:

   ```idris
   readSome : FileDesc -> Nat -> Task (Either Errno (List Bits8))
   readSome fd n = do
     r <- liftIO (readBytes fd n)
     case r of
       Left EAGAIN => awaitReadable fd *> readSome fd n
       other       => pure other
   ```

2. **A call that blocks and has no descriptor** (a regular file, which `epoll`
   always reports ready; SQLite; `fsync`). A `Point` would stop every task, so
   the call is run on another thread:

   ```idris
   blocking : IO a -> Task a      -- planned, with milestone 3
   ```

   The worker runs the action and calls the `Completion` through the inbox. A
   request that has not started can be cancelled; one that has started runs to
   its end and its result is dropped. It needs the thread pool of milestone 3,
   so it is not in milestone 1; until then `liftIO` blocks the scheduler, which
   is fine for short calls.

3. **A library with callbacks** (libcurl's multi interface, `c-ares`): implement
   a `Source`. Register the descriptors the library asks for (and its timer, as a
   scheduler timer), and in `drain` call the library so that it runs its
   callbacks; they call the `Completion`s.

4. **Anything else**: `Async` itself. Three things to write: start the operation,
   call `done` when it is over, and return the action that gives it up.

   ```idris
   myOp : Handle -> Task Reply
   myOp h = Async $ \sched, done => do
     tag <- startRequest h (\reply => done reply)
     pure (cancelRequest h tag)
   ```

Two rules for the author. `done` is called on the scheduler's thread (from
`drain`), or from any thread when it goes through the inbox; a `done` after a
cancel is ignored, but the buffers the operation uses must live until the
kernel or the library has really finished with them, not until the cancel.

## Using it from termui (milestone 2, implemented)

The master `epoll` is a descriptor that another `epoll` can wait for. termui's
`Loop` adds `pollFd sched` to its own set (`watchFd`, event `EReady`); when it
is readable the program calls `turn sched 0`. For that to be true whenever a
turn has work, the scheduler keeps a `timerfd` (a source) armed for its earliest
timer, and writes its inbox `eventfd` when a task was started or steps are
still ready at the end of a turn. The commands:

```idris
RunTask   : Task msg -> Cmd msg             -- run beside the program; the message it ends with is delivered
RunTaskAs : String -> Task msg -> Cmd msg   -- the same; a running task of that name is given up first
CancelTask : String -> Cmd msg
```

A task is `t >>= \m => Point (dispatch m)` (it runs on the thread of the loop,
so it can call the dispatch of the program). `RunTaskAs` and `CancelTask` use
`submitHandle` and `cancelTask` of the scheduler: the handle holds the scope the
task and everything it spawns run in. Unlike `Perform`, the loop does not stop
while a task waits, and a task can wait for a socket, a timer or another task.

## N:M (milestone 3)

One thread, the *reactor*, owns the scheduler: the run queue, the scopes, the
join cells, the promises, the timers and the table of the sources. Only it
touches them, so they stay plain `IORef`s. Any number of *workers* (threads)
only run actions that the reactor hands them; what comes back goes through
`env.post` (the inbox, already thread-safe), and so reaches the reactor again.
Go's or tokio's "a run queue and a poller per worker" is not what this is: it
would put every one of those structures under a lock.

Stages:

1. **`blocking` and a pool** (implemented). `blocking : IO a -> Task a` runs the
   action on a worker and ends with its result when the worker has put it in
   the inbox. The scheduler takes a number of workers (`newSchedulerWith n`,
   `runTaskWith n`); they are started *lazily*, up to `n`, when the first job
   comes, because the first thread flips rc2's reference counts to atomic for
   the rest of the program (`hybrid-refcount.md`), a cost a program that never
   offloads should not pay. With `n = 0` the action runs at once on the thread
   of the scheduler (1:M, and the same result). A job that has not started when
   its task is given up is dropped; one that has started runs to its end and its
   result is thrown away. `closeScheduler` stops the workers (jobs still queued
   are forgotten) and joins them.
2. **`Point` on the workers** (implemented, opt-in). `runTaskParallel n` (or the
   scheduler's `parallel` flag) puts the scheduler in *parallel mode*: a `Point`
   (`liftIO`) is run as `blocking` is, on a worker, and the task goes on with its
   result. The steps of one task stay in order; the `Point`s of different tasks
   run at the same time. The control (`>>=`, `both`, `race`, `spawn`, `Async`,
   promises) still goes back through the reactor, so this pays only for
   coarse `Point`s. It gives up the guarantee of the cooperative model that a
   `Point` is not interrupted by another task: what `Point`s share (an `IORef` two
   tasks both write) is now shared between threads, as with real threads.
   `onReactor : IO a -> Task a` (the constructor `Pinned`) is the `Point` that always
   runs on the thread of the scheduler, for what touches the state of the
   scheduler or of the program (`pure`, `map`, `yield`, the promise operations
   and termui's delivery of a message are pinned). With no workers the mode does
   nothing.

What a thread must not do: touch a scheduler structure (use `env.post`), or
keep a `Task` that it also gives to another thread. Everything handed to a
worker is an `IO ()` closure that owns what it captured.

`termui` creates its scheduler with a few workers; since they are started on
the first `blocking`, a program that never calls it stays single-threaded and
keeps the plain reference counts. The state of the UI (the model and `update`)
stays on the thread of the loop: a worker's result comes back as a message.

## Tests

`TestTask` does not depend on how fast the machine is.

- Whatever waits only for timers (and for descriptors that nobody has to answer
  in real time: a pipe the test itself writes to) runs on a **virtual clock**,
  `runTaskVirtual`. The clock starts at 0 and moves only when no step is ready,
  no source has anything and a timer is waiting: to that timer. `sleepFor 800`
  takes no time, the order of events is exact, and the time of the end can be
  checked (a `race` won by a 10 ms timer ends at 10, whatever the loser waits
  for). The scheduler can do this because every timer is its own: the real
  clock only matters through `timerfd` and `epoll_wait`, which a virtual
  clock does not use.
- What needs real threads (workers, `blocking`, a completion from another
  thread, parallel mode) is checked with **flags the jobs wait for**, never by
  elapsed time: two jobs `meet` (each sets its flag and waits up to 400 ms for
  the other's) and both get `True` only if they ran at the same time, as with two
  workers or parallel mode; with one worker, or with cooperative `Point`s, the
  first gives up and gets `False`. That the reactor goes on while a worker is
  busy is a job that waits for a tick that a real timer makes. That a queued job
  that is given up never runs: the worker is held by a job that waits for a flag
  set after the race.
- Checked: 40 runs in a row and 16 at once on 4 cores with four busy loops, all
  the same output; the ThreadSanitizer pass over `TestTask`.

Cases: `Seq`, deep left-nested binds and a loop of 200000 steps (no stack growth);
`Both`: results in order, the continuation runs once, when both are done;
`Race`: the loser is cancelled, its cleanups ran, a cancelled `sleepFor` or fd
wait does not delay the end; `Spawn`: runs after the continuation finished, and
is cancelled with its race; the epoll source on a pipe (readable and writable,
two waiters for one descriptor, hang-up, a regular file); timers in the order of
their deadlines; promises; `blocking`; `runTaskFirst`; parallel mode;
`runTask` returns `Nothing` for `Empty`.

## io_uring

`Control.Task.Uring` makes `io_uring` requests as `Task`s on `System.Linux.Uring`:

```idris
uringNop : Task (Either Errno ())
uringRead, uringWrite : FileDesc -> Buffer -> (nbytes : Bits32) -> (offset : Bits64) -> Task (Either Errno Nat)
uringSend, uringRecv : FileDesc -> Buffer -> (len : Bits64) -> (flags : Int32) -> Task (Either Errno Nat)
uringAccept : FileDesc -> (flags : Int32) -> Task (Either Errno FileDesc)
uringConnect : FileDesc -> (host : String) -> (port : Bits16) -> Task (Either Errno ())
uringOpenat : Maybe DirDesc -> String -> (flags : Bits32) -> (mode : Bits32) -> Task (Either Errno FileDesc)
uringClose : FileDesc -> Task (Either Errno ())
uringFsync : FileDesc -> (flags : Bits32) -> Task (Either Errno ())
```

No ring is passed around. Each scheduler has one ring (256 entries), which the
first request makes with `Env.slot` and adds to the scheduler as a source with
`Env.addSource`: the descriptor of the ring is readable while completions wait,
the master `epoll` reports it like any other source, and `drain` reaps them
(`pollCompletion` until nothing is left) and calls the `Completion` kept under
the tag of each request (the `user_data`, a counter of the ring). The ring is
released when the scheduler is closed; requests still in the kernel are
forgotten with it. A request is submitted at once (one system call each).

A request given up (it lost a `race`, its scope was cancelled) asks the kernel
to cancel it (`IORING_OP_ASYNC_CANCEL`). Its completion still comes and is
dropped, and the buffer or address it holds is kept alive by `System.Linux.Uring`
until then, by tag, as the rule for an `Async` asks. When the queue is full the
prepared entries are submitted to make room, and a request that still finds no
entry is answered with `EBUSY`. `uringConnect` resolves the name first, on a
worker thread (`blocking`), as `getaddrinfo` may ask a name server, and answers
`EINVAL` when it does not resolve.

Everything is done on the thread of the scheduler, which is where an `Async`
starts and `drain` runs: there is no request that a `Point` can make by mistake.

### Not needing liburing

A program needs liburing (its header when the C is compiled, `-luring` when it
is linked) only if a request is reachable from its `main`. Three things make it so:

- No module of `Control.Task` (the type, the scheduler, the sources, termui)
  imports `System.Linux.Uring` or `Control.Task.Uring`. `tests/verify.sh`
  checks that `Control/Task/Uring.idr` is the only importer.
- rc2 takes the headers and libraries only from the `%foreign` declarations
  that are left after dead code elimination. A program that imports
  `Control.Task.Uring` but refers to no request has none of them in its C
  (`TestTaskNoUring` builds without liburing and `verify.sh` looks for
  "liburing" in its generated C).
- The ring is made by the first request that runs, not by a module or by the
  scheduler: a program that refers to a request and does not reach it still needs
  the header to build, but makes no ring. Where `io_uring` is not available (an
  old kernel, a policy that forbids it) the first request answers `Left errno`.

`TestTaskUring` (skipped when gcc cannot find `liburing.h`) covers a nop, a
file written and read back, two requests at once, a read that waits for a
write of another task, a request given up by a race, and an error.

## Milestones

1. `Control.Task` and the single-threaded scheduler with the epoll source and
   the timers, the tests above, this document brought up to date. (Package
   `rc2base`; the modules are `Control.Task` for the type and instances,
   `Control.Task.Scheduler` for the scheduler and `Control.Task.Epoll` for the
   epoll source and `awaitReadable`.) The `Source` interface is in from the
   start, so that the epoll source is its first user and not a special case.
   The `io_uring` source is `Control.Task.Uring` (see "io_uring").
2. `Spawn` in termui's `Cmd`, with `pollFd` in its loop, and cancellation by handle.
3. N:M: worker threads, the atomic cells, the `eventfd` queue.

## Decisions

- `runTask` returns when nothing is left, as coop does; `runTaskFirst n` returns
  when the first task ends and gives up what is left (the operations are
  cancelled).
- `Time` is `Nat` milliseconds on the monotonic clock. A `TimeSpec` would
  promise a resolution the scheduler (a `timerfd` armed in whole milliseconds)
  does not have.
- A virtual clock (`runTaskVirtual`) for tests: see "Tests".
- Steps: a turn runs up to 1024 ready steps before it looks at the sources again
  (`stepBudget`), and re-arms the timer descriptor only when the earliest
  deadline changed. A step costs 0.74 microseconds (a loop of a million `liftIO`s
  in 0.74 s; one step per turn cost 4.5 microseconds, all in system calls).
  `yield` still puts the task behind the others.

## Open points

- Generalising `Task` to any `HasIO m` (a `TaskT m`, with `Task` as `TaskT IO`):
  the `Point`s would hold `m a`, and the scheduler would need a way to run
  them in `IO`. Nothing in the data type stands in the way; it is not needed yet.
- Whether a source may also give a timeout for the wait (`io_uring` has its own
  timeout operation); for now timers are the scheduler's.
- Several rings, a ring of another depth than 256, and the requests that do not
  fit an `Async` (a multishot accept gives many completions) are not done.
