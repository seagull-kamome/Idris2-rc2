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
  Point  : IO a -> Task a                        -- an action, run to completion
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
-- later, in other modules, with a handle of their own:
uringRead : Ring -> FileDesc -> ... -> Task (Either Errno Nat)
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

The state of a promise is plain `IORef`s: it is used from the thread of the
scheduler. Milestone 3 has to make it safe for several threads.

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

## Using it from termui (milestone 2)

The master `epoll` is a descriptor that another `epoll` can wait for. termui's
`Loop` adds `pollFd sched` to its own set; when it is readable it calls
`turn sched 0`. A new command

```idris
Spawn : Task msg -> Cmd msg        -- run alongside the program; its result is delivered as a message
```

submits `t >>= \m => Point (post m)`, where `post` is the `dispatch` of the
program (the task runs on the thread of the loop, so it can call it). Unlike
`Perform`, the loop does not stop while the task waits, and the task can wait
for a socket, a timer or another task. Cancelling a running task from the
program (by a handle that holds its scope) is part of that milestone.

## N:M (milestone 3)

Several threads each run `turn` on a scheduler of their own, or on one with a
shared run queue (a `Mutex` and a `Condition`; the poller is one of the
threads). Things to settle then:

- rc2's reference count is not atomic until the program first forks
  (`hybrid-refcount.md`): the scheduler starts its workers with `refc_fork`
  and not before, and a `Task` handed to another thread is one that is no
  longer used by this one;
- the join cells and the scopes become atomic (`casIORef`, or a lock);
- a program with a thread of its own state (termui) keeps it on its thread: the
  task posts its message through an `eventfd` queue that the loop reads, never
  by calling `update` from a worker;
- `Point` blocking one worker blocks only that worker, which is the reason to
  have more than one.

## Tests

Pure scheduling order needs no real I/O: a pipe (`System.Linux.Pipe`) or a
socketpair gives a descriptor that is ready when the test says, and the
timers use short real delays (tens of milliseconds) whose order, not length,
is checked. Planned cases:

- `Seq`, deep left-nested binds and a loop of a million steps (no stack growth);
- `Both`: results in order, the continuation runs once, when both are done;
- `Race`: the loser is cancelled, its cleanups ran (the descriptor is removed from
  the epoll set: check with `epollDel` failing with `ENOENT`), a cancelled
  `sleepFor` does not delay the end;
- `Spawn`: runs after the continuation finished, and is cancelled with its race;
- `Async` and the epoll source: readable and writable on a pipe, two tasks
  waiting for the same descriptor, hang-up wakes the waiter; a hand-made
  `Source` (a pipe written by the test) and a completion called from another
  thread through the inbox;
- timers: three sleepers wake in the order of their deadlines;
- `runTask` returns `Nothing` for `Empty`.

## Milestones

1. `Control.Task` and the single-threaded scheduler with the epoll source and
   the timers, the tests above, this document brought up to date. (Package
   `rc2base`; the modules are `Control.Task` for the type and instances,
   `Control.Task.Scheduler` for the scheduler and `Control.Task.Epoll` for the
   epoll source and `awaitReadable`.) The `Source` interface is in from the
   start, so that the epoll source is its first user and not a special case.
   An `io_uring` source (`libs/iouring`) is a separate, later step.
2. `Spawn` in termui's `Cmd`, with `pollFd` in its loop, and cancellation by handle.
3. N:M: worker threads, the atomic cells, the `eventfd` queue.

## Open points

- Whether `runTask` should return when the root finishes (cancelling what is
  left) as an option; coop returns when everything is done.
- `Time` as `Nat` milliseconds or a `TimeSpec` of `System.Posix.Time`.
- The step budget against the round robin after each `Point`.
- The shape of `TaskT m`, once a second substrate is wanted.
- Whether a source may also give a timeout for the wait (`io_uring` has its own
  timeout operation); for now timers are the scheduler's.
- How an `io_uring` request that needs a buffer keeps it alive until the
  completion (the `Completion` closure holds it; to be settled with `libs/iouring`).
