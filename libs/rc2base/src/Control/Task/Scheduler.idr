||| The scheduler of `Control.Task`: runs the tasks of one thread, waits for
||| the sources (the readiness of descriptors and any other the program
||| adds) and the timers. Design: libs/rc2base/doc/task.md.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Control.Task.Scheduler

import Control.Task
import Control.Task.Epoll
import Control.Task.Pool
import Control.Task.Source
import Data.Bits
import Data.IORef
import Data.List
import Data.Maybe
import Data.Queue
import Data.SortedMap
import System.Concurrency
import System.Linux.Epoll
import System.Linux.Eventfd
import System.Linux.Timerfd
import System.Posix.Errno
import System.Posix.FileDesc
import System.Posix.Time

%default covering

-------------------------------------------------------------------------------
-- Scopes

-- The tasks of a `race` run in a scope of their own; cancelling it gives up
-- their operations, drops their ready steps and cancels the scopes below.
record Scope where
  constructor MkScope
  cancelled : IORef Bool
  cleanups : IORef (SortedMap Nat (IO ()))
  children : IORef (SortedMap Nat Scope)

newRootScope : IO Scope
newRootScope = [| MkScope (newIORef False) (newIORef empty) (newIORef empty) |]

cancelScope : Scope -> IO ()
cancelScope sc = do
  done <- readIORef sc.cancelled
  unless done $ do
    writeIORef sc.cancelled True
    cs <- readIORef sc.cleanups
    writeIORef sc.cleanups empty
    kids <- readIORef sc.children
    writeIORef sc.children empty
    traverse_ id (values cs)
    traverse_ cancelScope (values kids)

-------------------------------------------------------------------------------
-- The scheduler

-- A value of any type, kept by `Env.slot` under a key that fixes its type.
data Held : Type where
  Hold : a -> Held

-- A ready step of a scope, and what to do instead if the step is dropped (its
-- scope was cancelled before it ran, or the scheduler was closed): the steps
-- that carry a resource or a value hand it back there.
record Step where
  constructor MkStep
  scope : Scope
  act : IO ()
  drop : IO ()

export
record Scheduler where
  constructor MkScheduler
  runQ : IORef (Queue Step)
  pending : IORef Nat                          -- operations started and not over
  counter : IORef Nat
  timers : IORef (SortedMap (Time, Nat) (IO ()))
  master : EPoll
  sources : IORef (SortedMap Int32 Source)
  root : Scope
  watcher : FdWatcher
  lock : Mutex
  inbox : IORef (List (IO ()))
  inboxFd : FileDesc
  timerFd : FileDesc                           -- armed for the earliest timer
  armed : IORef (Maybe Time)                   -- the deadline `timerFd` is armed for
  pool : Pool                                  -- the workers of `blocking`
  parallel : IORef Bool                        -- `Point`s run on the workers
  virtual : IORef (Maybe Time)                 -- a clock that only the scheduler moves
  slots : IORef (SortedMap String Held)        -- `Env.slot`
  releases : IORef (List (IO ()))              -- what releases the slots, last made first

-- A step that must not just vanish: `drop` runs if it does.
enqueueOwning : Scheduler -> Scope -> (act, drop : IO ()) -> IO ()
enqueueOwning s sc act drop = modifyIORef s.runQ (Queue.enqueue (MkStep sc act drop))

fresh : Scheduler -> IO Nat
fresh s = do
  n <- readIORef s.counter
  writeIORef s.counter (S n)
  pure n

-- A step that, if it is dropped, is simply gone.
enqueue : Scheduler -> Scope -> IO () -> IO ()
enqueue s sc act = enqueueOwning s sc act (pure ())

||| The monotonic clock in milliseconds.
nowMs : IO Time
nowMs = do
  Right t <- clock_gettime CLOCK_MONOTONIC
    | Left _ => pure 0
  pure (cast (t.tvSec * 1000 + t.tvNsec `div` 1000000))

-- The time of the scheduler: the monotonic clock, or the virtual clock of
-- `runTaskVirtual`.
schedNow : Scheduler -> IO Time
schedNow s = readIORef s.virtual >>= maybe nowMs pure

-- Point the timer descriptor at the earliest timer (or disarm it): the master
-- `epoll` is then readable when a timer is due, whoever waits for it.
armTimerFd : Scheduler -> IO ()
armTimerFd s = do
  virt <- readIORef s.virtual
  -- a virtual clock does not wait: `turn` moves it
  unless (isJust virt) $ do
    tm <- readIORef s.timers
    was <- readIORef s.armed
    let next = map (fst . fst) (leftMost tm)
    -- one system call only when the earliest deadline changed
    when (next /= was) $ do
      writeIORef s.armed next
      case next of
        Nothing => ignore (timerfd_settime s.timerFd 0 (MkITimerSpec (MkTimeSpec 0 0) (MkTimeSpec 0 0)))
        Just t => do
          now <- nowMs
          -- an all-zero value would disarm the timer; `Int`, not `Nat`, for the division
          -- (KNOWN-BUGS.md), so the wait is capped (the timer is armed again when it goes off early)
          let ms = the Int (cast (min 1099511627776 {- 2^40 -} (max 1 (t `minus` now))))
          ignore (timerfd_settime s.timerFd 0
                    (MkITimerSpec (MkTimeSpec 0 0) (MkTimeSpec (cast (ms `div` 1000)) (cast ((ms `mod` 1000) * 1000000)))))

-- A timer was added for `t`: the descriptor is armed again only if `t` is earlier
-- than what it is armed for. A timer that was withdrawn leaves the descriptor armed
-- for its time; the wake-up that follows finds nothing due and `fireTimers` arms the
-- next one, which costs less than two system calls for every timeout that never fires.
armForNew : Scheduler -> Time -> IO ()
armForNew s t = do
  was <- readIORef s.armed
  when (maybe True (t <) was) (armTimerFd s)

-- Make the master `epoll` readable, so that whoever waits for it calls `turn`.
wake : Scheduler -> IO ()
wake s = ignore (eventfdWrite s.inboxFd 1)

-- Run an action on the thread of the scheduler, from any thread.
postTo : Scheduler -> IO () -> IO ()
postTo s act = do
  mutexAcquire s.lock
  modifyIORef s.inbox (act ::)
  mutexRelease s.lock
  ignore (eventfdWrite s.inboxFd 1)

removeSource : Scheduler -> Source -> IO ()
removeSource s src = do
  ignore (epollDel s.master src.pollFd)
  modifyIORef s.sources (delete src.pollFd.rawfd)

addSourceRaw : Scheduler -> Source -> IO (Either Errno ())
addSourceRaw s src = do
  r <- epollAdd s.master src.pollFd EPOLLIN
  case r of
    Left e => pure (Left e)
    Right () => do
      modifyIORef s.sources (insert src.pollFd.rawfd src)
      pure (Right ())

envOf : Scheduler -> Env
envOf s = MkEnv (schedNow s) addTimer (\fd, ev, done => watch s.watcher fd ev done) (postTo s) (offload s.pool)
                (\src => map (const (MkCancel (removeSource s src))) <$> addSourceRaw s src) slotOf
  where
    slotOf : {0 a : Type} -> String -> IO (Either Errno (a, IO ())) -> IO (Either Errno a)
    slotOf key make = do
      held <- lookup key <$> readIORef s.slots
      case held of
        Just (Hold v) => pure (Right (believe_me v))
        Nothing => do
          Right (v, release) <- make
            | Left e => pure (Left e)
          modifyIORef s.slots (insert key (Hold v))
          modifyIORef s.releases (release ::)
          pure (Right v)

    addTimer : Time -> IO () -> IO Cancel
    addTimer t act = do
      ident <- fresh s
      modifyIORef s.timers (insert (t, ident) act)
      armForNew s t
      pure (MkCancel (modifyIORef s.timers (delete (t, ident))))

-------------------------------------------------------------------------------
-- The interpreter

-- How many steps a worker runs one after the other before the task goes back to the
-- scheduler, so that a loop of `Point`s cannot keep it away for ever.
chainLength : Nat
chainLength = 64

-- The `Point`s and `PointThen`s at the start of the task, run one after the other
-- (until the scope is cancelled or `fuel` is out); `Left` is the task that is left.
chain : IO Bool -> (fuel : Nat) -> Task a -> IO (Either (Task a) a)
chain gone Z t = pure (Left t)
chain gone (S n) (Point io) = Right <$> io
chain gone (S n) (PointThen io f) = do
  a <- io
  stop <- gone
  -- (given up: nothing will be done with what is left)
  if stop then pure (Left Empty) else chain gone n (f a)
chain gone (S n) (Map f t) = either (Left . Map f) (Right . f) <$> chain gone n t
chain gone _ t = pure (Left t)

mutual
  run : Scheduler -> Scope -> Task a -> (a -> IO ()) -> IO ()
  run s sc (Pinned io) k = enqueue s sc (io >>= k)
  run s sc (Point io) k = do
    par <- readIORef s.parallel
    if par
       then runAsync s sc (\env, done => env.offload (io >>= \a => env.post (done a))) k
       else enqueue s sc (io >>= k)
  run s sc (PointThen io f) k = do
    par <- readIORef s.parallel
    if par
       then runAsync s sc (\env, done => env.offload (chain (readIORef sc.cancelled) chainLength (PointThen io f)
                                                       >>= env.post . done))
                      (\r => either (\t => run s sc t k) k r)
       else run s sc (Point io) (\a => run s sc (f a) k)
  run s sc (Seq t f) k = run s sc t (\a => run s sc (f a) k)
  run s sc (Map f t) k = run s sc t (\a => k (f a))
  run s sc (Both l r) k = runBoth s sc l r k
  run s sc (Race Empty r) k = run s sc r k
  run s sc (Race l Empty) k = run s sc l k
  run s sc (Race l r) k = runRace s sc l r k
  run s sc (Spawn t) k = do
    enqueue s sc (run s sc t (\_ => pure ()))
    k ()
  run s sc (Async f) k = runAsync s sc f k
  run s sc (Handoff f undo) k = runHandoff s sc f undo k
  run s sc (Finally release t) k = runFinally s sc release t k
  run s sc (SpawnOwning release t) k = do
    enqueueOwning s sc (run s sc t (\_ => pure ())) release
    k ()
  run _ _ Empty _ = pure ()

  runBoth : Scheduler -> Scope -> Task a -> Task b -> ((a, b) -> IO ()) -> IO ()
  runBoth s sc l r k = do
    ra <- newIORef Nothing
    rb <- newIORef Nothing
    enqueue s sc $ run s sc l $ \a => do
      mb <- readIORef rb
      case mb of
        Just b => enqueue s sc (k (a, b))
        Nothing => writeIORef ra (Just a)
    enqueue s sc $ run s sc r $ \b => do
      ma <- readIORef ra
      case ma of
        Just a => enqueue s sc (k (a, b))
        Nothing => writeIORef rb (Just b)

  runRace : Scheduler -> Scope -> Task a -> Task a -> (a -> IO ()) -> IO ()
  runRace s sc l r k = do
    ident <- fresh s
    child <- newRootScope
    modifyIORef sc.children (insert ident child)
    won <- newIORef False
    let finish = \a => do
          already <- readIORef won
          unless already $ do
            writeIORef won True
            cancelScope child
            modifyIORef sc.children (delete ident)
            enqueue s sc (k a)
    enqueue s child (run s child l finish)
    enqueue s child (run s child r finish)

  runAsync : Scheduler -> Scope -> (Env -> Completion a -> IO Cancel) -> (a -> IO ()) -> IO ()
  runAsync s sc f k = do
    gone <- readIORef sc.cancelled
    unless gone $ do
      ident <- fresh s
      fired <- newIORef False
      modifyIORef s.pending S
      let complete = \x => do
            already <- readIORef fired
            unless already $ do
              writeIORef fired True
              modifyIORef s.pending (`minus` 1)
              modifyIORef sc.cleanups (delete ident)
              enqueue s sc (k x)
      giveUp <- f (envOf s) complete
      already <- readIORef fired
      unless already $
        modifyIORef sc.cleanups $ insert ident $ do
          over <- readIORef fired
          unless over $ do
            writeIORef fired True
            modifyIORef s.pending (`minus` 1)
            runCancel giveUp

  runHandoff : Scheduler -> Scope -> (Env -> Completion a -> IO Cancel) -> (a -> IO ()) -> (a -> IO ()) -> IO ()
  runHandoff s sc f undo k = do
    gone <- readIORef sc.cancelled
    unless gone $ do
      ident <- fresh s
      fired <- newIORef False
      modifyIORef s.pending S
      let complete = \x => do
            already <- readIORef fired
            if already then undo x else do
              writeIORef fired True
              modifyIORef s.pending (`minus` 1)
              modifyIORef sc.cleanups (delete ident)
              enqueueOwning s sc (k x) (undo x)
      giveUp <- f (envOf s) complete
      already <- readIORef fired
      unless already $
        modifyIORef sc.cleanups $ insert ident $ do
          over <- readIORef fired
          unless over $ do
            writeIORef fired True
            modifyIORef s.pending (`minus` 1)
            runCancel giveUp

  -- The action is registered as a cleanup of the scope in the step that starts
  -- the task, and taken out in the step that ends it, with the result.
  runFinally : Scheduler -> Scope -> (Maybe b -> IO ()) -> Task b -> (b -> IO ()) -> IO ()
  runFinally s sc release t k = do
    gone <- readIORef sc.cancelled
    if gone then release Nothing else do
      ident <- fresh s
      over <- newIORef False
      modifyIORef sc.cleanups $ insert ident $ do
        already <- readIORef over
        unless already $ do
          writeIORef over True
          release Nothing
      run s sc t $ \r => do
        already <- readIORef over
        unless already $ do
          writeIORef over True
          modifyIORef sc.cleanups (delete ident)
          release (Just r)
          k r

-------------------------------------------------------------------------------
-- Turns

-- The steps a turn runs before it looks at the sources again: tasks that
-- only compute are not slowed by a system call per step, and a source waits at
-- most this many steps.
stepBudget : Nat
stepBudget = 1024

-- Run up to `n` of the ready steps.
runBatch : Scheduler -> Nat -> IO ()
runBatch _ Z = pure ()
runBatch s (S n) = do
  q <- readIORef s.runQ
  case dequeue q of
    Nothing => pure ()
    Just (step, rest) => do
      writeIORef s.runQ rest
      gone <- readIORef step.scope.cancelled
      if gone then step.drop else step.act
      runBatch s n

-- Run the timers that are due, then point the descriptor at the next.
fireTimers : Scheduler -> IO ()
fireTimers s = do
  go
  armTimerFd s
  where
    go : IO ()
    go = do
      now <- schedNow s
      tm <- readIORef s.timers
      case leftMost tm of
        Just ((t, ident), act) =>
          if t <= now
             then do modifyIORef s.timers (delete (t, ident))
                     act
                     go
             else pure ()
        Nothing => pure ()

-------------------------------------------------------------------------------
-- The public interface

||| A scheduler with up to `workers` threads for `blocking`, started when the
||| first job comes.
export
newSchedulerWith : (workers : Nat) -> IO (Either Errno Scheduler)
newSchedulerWith workers = do
  Right master <- epollCreate 16
    | Left e => pure (Left e)
  Right watcher <- newFdWatcher
    | Left e => ignore (epollClose master) *> pure (Left e)
  Right inboxFd <- eventfd 0 (EFD_NONBLOCK .|. EFD_CLOEXEC)
    | Left e => ignore (epollClose master) *> closeFdWatcher watcher *> pure (Left e)
  Right timerFd <- timerfd_create CLOCK_MONOTONIC (TFD_NONBLOCK .|. TFD_CLOEXEC)
    | Left e => ignore (epollClose master) *> closeFdWatcher watcher *> ignore (close inboxFd) *> pure (Left e)
  pool <- newPool workers
  lock <- makeMutex
  root <- newRootScope
  s <- [| MkScheduler (newIORef Queue.empty) (newIORef 0) (newIORef 0) (newIORef empty) (pure master)
                      (newIORef empty) (pure root) (pure watcher) (pure lock) (newIORef []) (pure inboxFd) (pure timerFd) (newIORef Nothing) (pure pool) (newIORef False) (newIORef Nothing) (newIORef empty) (newIORef []) |]
  Right () <- addSourceRaw s (watcherSource watcher)
    | Left e => pure (Left e)
  Right () <- addSourceRaw s (MkSource inboxFd (drainInbox s))
    | Left e => pure (Left e)
  Right () <- addSourceRaw s (MkSource timerFd (ignore (timerfd_read timerFd) *> writeIORef s.armed Nothing))
    | Left e => pure (Left e)
  pure (Right s)
  where
    drainInbox : Scheduler -> IO ()
    drainInbox s = do
      _ <- eventfdRead s.inboxFd
      mutexAcquire s.lock
      acts <- readIORef s.inbox
      writeIORef s.inbox []
      mutexRelease s.lock
      traverse_ id (reverse acts)

||| A scheduler with the sources for descriptors and for other threads, and no
||| workers: `blocking` runs its action on the thread of the scheduler.
export
newScheduler : IO (Either Errno Scheduler)
newScheduler = newSchedulerWith 0

||| Release the descriptors of the scheduler. Operations still pending are
||| forgotten.
export
closeScheduler : Scheduler -> IO ()
closeScheduler s = do
  left <- readIORef s.runQ
  writeIORef s.runQ Queue.empty
  traverse_ (.drop) (Queue.toList left)
  -- The workers first: a job that is running may still use a slot, so the
  -- slots are released only after the pool has joined its threads.
  closePool s.pool
  releases <- readIORef s.releases
  sequence_ releases
  ignore (epollClose s.master)
  closeFdWatcher s.watcher
  ignore (close s.inboxFd)
  ignore (close s.timerFd)

||| Add a source of completions: its `pollFd` is waited for with the others.
export
addSource : Scheduler -> Source -> IO (Either Errno ())
addSource = addSourceRaw

||| Start a task. A loop that waits for `pollFd` is told to call `turn`.
export
submit : Scheduler -> Task () -> IO ()
submit s t = run s s.root t (\_ => pure ()) *> wake s

||| A task that was started with `submitHandle`, to be given up.
export
record TaskHandle where
  constructor MkTaskHandle
  scope : Scope
  detach : IO ()

||| Start a task that `cancelTask` can give up: everything it runs or spawns
||| is cancelled with it.
export
submitHandle : Scheduler -> Task () -> IO TaskHandle
submitHandle s t = do
  child <- newRootScope
  ident <- fresh s
  let detach = modifyIORef s.root.children (delete ident)
  modifyIORef s.root.children (insert ident child)
  run s child t (\_ => detach)
  wake s
  pure (MkTaskHandle child detach)

||| Give up a task: its operations are cancelled (their `Cancel`s run), and the
||| steps it has ready are dropped. A step that has started is not interrupted.
export
cancelTask : TaskHandle -> IO ()
cancelTask h = cancelScope h.scope *> h.detach

||| The descriptor that is readable when a turn has something to do (a task
||| started, a completion or a timer waiting), to be waited for by another
||| `epoll`; then call `turn s 0`.
export
pollFd : Scheduler -> FileDesc
pollFd s = epollDescriptor s.master

||| Run the ready tasks, wait once at most `timeoutMs` milliseconds (negative:
||| until something happens) for the sources and the timers, and run what they
||| woke. `False` when nothing is left: no ready step, no timer, no operation
||| pending. When steps are still ready at the end (a task that keeps
||| yielding) `pollFd` is made readable again. When nothing is left the sources
||| are still looked at once, without waiting: a wake-up whose work was done in
||| the batch above (the last task ended) would else stay readable, and a loop
||| that waits for `pollFd` would call `turn` again at once, for ever.
export
turn : Scheduler -> (timeoutMs : Int32) -> IO Bool
turn s timeoutMs = do
  runBatch s stepBudget
  fireTimers s
  q' <- readIORef s.runQ
  pend <- readIORef s.pending
  let idle = Queue.isEmpty q' && pend == 0
  virt <- readIORef s.virtual
  timers <- readIORef s.timers
  -- a virtual clock does not wait for a timer: look, and move it if nothing else happens
  let wait = if idle || not (Queue.isEmpty q') || (isJust virt && not (null timers)) then 0 else timeoutMs
  Right evs <- epollWait s.master wait
    | Left _ => pure (not idle)
  if idle && null evs
     then pure False
     else do
       srcs <- readIORef s.sources
       traverse_ (\ev => maybe (pure ()) (.drain) (lookup ev.fd srcs)) evs
       when (isJust virt && null evs && Queue.isEmpty q') $
         for_ (leftMost timers) $ \((t, _), _) => writeIORef s.virtual (Just t)
       fireTimers s
       runBatch s stepBudget
       q3 <- readIORef s.runQ
       unless (Queue.isEmpty q3) (wake s)
       if idle
          then do
            pend3 <- readIORef s.pending
            pure (not (Queue.isEmpty q3 && pend3 == 0))
          else pure True

runWithTime : (virtual : Bool) -> (parallel : Bool) -> (untilRoot : Bool) -> (workers : Nat) -> Task a -> IO (Maybe a, Time)
runWithTime virt par untilRoot workers t = do
  Right s <- newSchedulerWith workers
    | Left _ => pure (Nothing, 0)
  when virt (writeIORef s.virtual (Just 0))
  when (par && workers > 0) (writeIORef s.parallel True)
  res <- newIORef Nothing
  submit s (Seq t (\a => Pinned (writeIORef res (Just a))))
  loop s res
  -- what is left is given up
  when untilRoot (cancelScope s.root)
  end <- schedNow s
  closeScheduler s
  r <- readIORef res
  pure (r, end)
  where
    loop : Scheduler -> IORef (Maybe a) -> IO ()
    loop s res = do
      done <- readIORef res
      unless (untilRoot && isJust done) $ do
        more <- turn s (-1)
        when more (loop s res)

runWith : (parallel : Bool) -> (untilRoot : Bool) -> (workers : Nat) -> Task a -> IO (Maybe a)
runWith par untilRoot workers t = map fst (runWithTime False par untilRoot workers t)

||| Run a task and everything it starts until nothing is left; its result,
||| `Nothing` if it never finished (it was `Empty`, or was cancelled).
export
runTask : Task a -> IO (Maybe a)
runTask = runWith False False 0

||| `runTask` with up to `workers` threads for `blocking`.
export
runTaskWith : (workers : Nat) -> Task a -> IO (Maybe a)
runTaskWith = runWith False False

||| `runTask` in parallel mode: the `Point`s (`liftIO`) of every task run on up to
||| `workers` threads, one after the other for a task but at the same time for
||| different tasks; the control of the tasks (`both`, `race`, `spawn`, promises, the
||| waits) stays on one thread. The continuation of a `Point` (the function after `>>=`)
||| is evaluated on the worker too, and the `Point`s that follow are run there without a
||| return to the scheduler. The action of a `Point` may then run at the same time as
||| those of other tasks: what it shares must be safe for that, and what must stay on
||| the thread of the scheduler is written with `onReactor`.
export
runTaskParallel : (workers : Nat) -> Task a -> IO (Maybe a)
runTaskParallel = runWith True False

||| `runTaskWith`, but it returns when the first task ends: what is still
||| running or waiting is given up (the operations are cancelled), not waited for.
export
runTaskFirst : (workers : Nat) -> Task a -> IO (Maybe a)
runTaskFirst = runWith False True

||| `runTask` on a virtual clock that starts at 0 and moves only when nothing
||| else can happen, to the next timer: `sleepFor` takes no real time and the
||| order of events does not depend on how fast the machine is. The result is
||| paired with the time at the end. For tasks that only wait for timers and
||| each other; real descriptors can be waited for, but a clock that does not
||| wait is no help when something outside (a worker, a peer) is to answer in
||| real time.
export
runTaskVirtual : Task a -> IO (Maybe a, Time)
runTaskVirtual = runWithTime True False False 0
