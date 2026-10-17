# `Control.Task`: cooperative tasks on epoll

Status: design. Nothing described here is implemented yet; the milestones
at the end say in which order it will be.

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
| waiting | `sleepTill` of a model or wall clock | `epoll`: readiness of a descriptor, and timers |
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
  Await  : Waitable -> Task Ready                -- wait for an event
  Empty  : Task a                                -- never finishes
```

```idris
data Waitable
  = Readable FileDesc          -- readable (or an error or hang-up: they wake the waiter too)
  | Writable FileDesc
  | Until Time                 -- a point on the monotonic clock
```

`Ready` tells which of `EPOLLIN`, `EPOLLOUT`, `EPOLLERR`, `EPOLLHUP` came (for
`Until` it is empty). `Monad`, `Applicative` (sequential, as in coop: `<*>` is
`>>=`), `HasIO` (`liftIO = Point`) and `Alternative` (`<|>` = `Race`) are
implemented. The parallel `Applicative` is a named implementation, `Concurrent`,
as in coop, because `a *> b` must mean "a, then b".

Functions built on these: `sleepFor`, `sleepTill`, `awaitReadable`,
`awaitWritable`, `both` (`Both`), `race : Task a -> Task b -> Task (Either a b)`,
`spawn`, `yield`, `forever`.

A `Point` runs to completion on the scheduler's thread: a blocking call in it
blocks every task. Use non-blocking descriptors and `Await` for waiting.

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
  run queue of a cancelled scope is dropped when it is taken. An `Await` puts
  a cleanup in its scope that takes the waiter out of the table of the
  scheduler (and `epoll_ctl DEL`s the descriptor when it was the last), so a
  cancelled wait costs nothing afterwards. A `Point` that has started is never
  interrupted.
- **Fairness.** A task is put at the back of the run queue after each `Point`,
  so a loop of actions cannot starve the others. (A step budget per turn is the
  first thing to try if this costs too much.)

## The scheduler

```idris
record Scheduler where
  runQueue : Queue (Scope, Task ())     -- ready
  waiters  : IORef (SortedMap Int32 (List Waiter))  -- by descriptor
  timers   : IORef (SortedMap Time (Queue Timer))   -- by deadline
  epoll    : EPoll
```

One turn:

1. run the ready tasks until the run queue is empty (new ones that they
   make are run too, round robin);
2. work out the timeout: `0` if something is ready, else the time to the
   earliest timer, else `-1` (forever) if there are waiters, and finish if there
   is nothing at all;
3. `epollWait`; for each ready descriptor, wake the waiters whose events
   match (their continuations go to the run queue), then fix the mask of the
   descriptor, `epollMod` to what the remaining waiters want or `epollDel` if
   there are none; the registration is level-triggered and the waiters are
   one-shot, so no `EPOLLONESHOT` is needed;
4. move the timers whose deadline has passed to the run queue.

Timers are kept in the scheduler (a map by deadline, with `CLOCK_MONOTONIC`
time) and become the timeout of `epollWait`; no `timerfd` is created, so a
thousand sleeping tasks use no descriptors. The resolution is a millisecond;
the timeout is rounded up so that a wait never wakes early.

The pieces are public, so that another loop can drive the scheduler:

```idris
newScheduler : IO (Either Errno Scheduler)
submit       : Scheduler -> Task () -> IO ()          -- start a task (in the root scope)
pollFd       : Scheduler -> FileDesc                  -- the epoll descriptor, readable when a turn has work
turn         : Scheduler -> (timeoutMs : Int32) -> IO Bool   -- run ready tasks, wait at most the timeout once; False when nothing is left
runTask      : Task a -> IO (Maybe a)                 -- new scheduler, submit, turn until nothing is left
```

`runTask` gives `Nothing` if the root task never finished (it was `Empty`, or
waits for something that cannot happen: nothing is left to run). It returns when
no task remains, spawned ones included, as coop does.

## Using it from termui (milestone 2)

An `epoll` descriptor can itself be waited for by another `epoll`. termui's
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
- `Await`: readable and writable on a pipe, two tasks waiting for the same
  descriptor, hang-up wakes the waiter;
- timers: three sleepers wake in the order of their deadlines;
- `runTask` returns `Nothing` for `Empty`.

## Milestones

1. `Control.Task` and the single-threaded scheduler, the tests above, this
   document brought up to date. (Package `rc2base`; the modules are
   `Control.Task` for the type and instances and `Control.Task.Scheduler`
   for the scheduler.)
2. `Spawn` in termui's `Cmd`, with `pollFd` in its loop, and cancellation by handle.
3. N:M: worker threads, the atomic cells, the `eventfd` queue.

## Open points

- Whether `runTask` should return when the root finishes (cancelling what is
  left) as an option; coop returns when everything is done.
- `Time` as `Nat` milliseconds or a `TimeSpec` of `System.Posix.Time`.
- The step budget against the round robin after each `Point`.
- The shape of `TaskT m`, once a second substrate is wanted.
