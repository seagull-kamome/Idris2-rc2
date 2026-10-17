||| Cooperative tasks: a monad of logical threads run by the scheduler of
||| `Control.Task.Scheduler`, after idris2-coop. A `Task` is a data structure
||| built by `>>=`, `both`, `race` and `spawn`; waiting for a descriptor, a
||| timer or any other asynchronous operation is `Async`. Design and
||| semantics: libs/rc2base/doc/task.md.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Control.Task

import Data.IORef
import Data.List
import System.Linux.Epoll
import System.Posix.FileDesc

%default covering

-------------------------------------------------------------------------------
-- The data type

||| A point on the monotonic clock, in milliseconds.
public export
Time : Type
Time = Nat

||| What gives an operation up. (A type of its own and not a bare `IO ()`:
||| an `IO Cancel` is then an action that returns a value, and `TestTask`, whose
||| operations hand it back after calling their completion, guards rc2's world
||| arity raising against treating it as a second world lambda.)
public export
data Cancel = MkCancel (IO ())

||| Nothing to give up.
public export
noCancel : Cancel
noCancel = MkCancel (pure ())

||| Give the operation up.
export
runCancel : Cancel -> IO ()
runCancel (MkCancel act) = act

||| Tell the scheduler that an operation is done.
public export
Completion : Type -> Type
Completion a = a -> IO ()

||| What the scheduler offers to an `Async`.
public export
record Env where
  constructor MkEnv
  ||| The monotonic clock.
  now : IO Time
  ||| Run the action at a time; the result cancels it.
  addTimer : Time -> IO () -> IO Cancel
  ||| Wake with the events that came when the descriptor is ready for one of
  ||| them (`EPOLLERR` and `EPOLLHUP` wake it too); the result cancels the wait.
  watchFd : FileDesc -> EpollEvents -> Completion EpollEvents -> IO Cancel
  ||| Run the action on the thread of the scheduler. The one function of an
  ||| `Env` that any thread may call.
  post : IO () -> IO ()
  ||| Run the action on a worker thread (at once on this one if the scheduler has
  ||| no workers); the result takes it back if it has not started.
  offload : IO () -> IO Cancel

public export
data Task : Type -> Type where
  ||| An action, run to completion on the thread of the scheduler.
  Point : IO a -> Task a
  Seq : Task a -> (a -> Task b) -> Task b
  ||| Run together, wait for both.
  Both : Task a -> Task b -> Task (a, b)
  ||| The first to finish wins and the other is cancelled.
  Race : Task a -> Task a -> Task a
  ||| Run alongside the continuation, in the same scope.
  Spawn : Task () -> Task ()
  ||| Start an operation and wait for it: it calls the completion when it is
  ||| done, and returns the action that gives it up.
  Async : (Env -> Completion a -> IO Cancel) -> Task a
  ||| Never finishes.
  Empty : Task a

-------------------------------------------------------------------------------
-- Instances

export
Functor Task where
  map f t = Seq t (\a => Point (pure (f a)))

export
Applicative Task where
  pure x = Point (pure x)
  f <*> x = Seq f (\g => map g x)

export
Monad Task where
  (>>=) = Seq

export
HasIO Task where
  liftIO = Point

||| `empty` never finishes; `<|>` is a race.
export
Alternative Task where
  empty = Empty
  l <|> r = Race l r

||| The applicative whose `<*>` runs both sides together, as `both` does.
export
[Concurrent] Applicative Task where
  pure x = Point (pure x)
  f <*> x = map (\(g, a) => g a) (Both f x)

-------------------------------------------------------------------------------
-- Operations

||| Run two tasks together and wait for both.
export
both : Task a -> Task b -> Task (a, b)
both = Both

||| The first to finish wins; the other is cancelled.
export
race : Task a -> Task b -> Task (Either a b)
race l r = Race (map Left l) (map Right r)

||| Run a task alongside the rest.
export
spawn : Task () -> Task ()
spawn = Spawn

||| Let the other ready tasks run.
export
yield : Task ()
yield = Point (pure ())

||| Wait until a time on the monotonic clock.
export
sleepTill : Time -> Task ()
sleepTill t = Async (\env, done => env.addTimer t (done ()))

||| Wait for a number of milliseconds.
export
sleepFor : Nat -> Task ()
sleepFor ms = Async (\env, done => do
  t <- env.now
  env.addTimer (t + ms) (done ()))

||| Wait until one of the events happens on the descriptor; the result is the
||| events that did.
export
awaitEvents : FileDesc -> EpollEvents -> Task EpollEvents
awaitEvents fd events = Async (\env, done => env.watchFd fd events done)

||| Wait until the descriptor can be read (or has an error or hung up).
export
awaitReadable : FileDesc -> Task EpollEvents
awaitReadable fd = awaitEvents fd EPOLLIN

||| Wait until the descriptor can be written (or has an error or hung up).
export
awaitWritable : FileDesc -> Task EpollEvents
awaitWritable fd = awaitEvents fd EPOLLOUT

||| Run an action that may block (a regular file, SQLite, a long computation) on a
||| worker thread, and go on with its result. The scheduler keeps going meanwhile.
||| With no workers (the default) it runs at once, like a `Point`. If the task is
||| given up before the action starts, it never runs; one that has started runs
||| to its end and the result is thrown away.
export
blocking : IO a -> Task a
blocking act = Async (\env, done => env.offload (do a <- act; env.post (done a)))

||| Do it again and again.
export
forever : Task a -> Task b
forever t = Seq t (\_ => forever t)

-------------------------------------------------------------------------------
-- Promises

-- Waiters are told with `Just` the result, or `Nothing` when the task that was to
-- make it was given up.
data PromiseState a
  = Pending (List (Nat, Maybe a -> IO ()))
  | Fulfilled a
  | Abandoned

||| The result of a task started with `fork`, that other tasks can wait for.
export
record Promise a where
  constructor MkPromise
  state : IORef (PromiseState a)
  counter : IORef Nat
  guard : IORef (IO ())     -- ends the sentinel that watches the producer

-- Settle the promise once; later calls do nothing. The waiters are told.
settle : Promise a -> PromiseState a -> Maybe a -> IO ()
settle p final answer = do
  st <- readIORef p.state
  case st of
    Pending ws => do
      writeIORef p.state final
      traverse_ (\w => (snd w) answer) ws
    _ => pure ()

||| Start a task beside the rest and get a promise of its result.
||| Giving the task up (its scope is cancelled before it ends, by a `race` it
||| lost, say) abandons the promise: `waitMaybe` then answers `Nothing`.
export
fork : Task a -> Task (Promise a)
fork t = do
  p <- liftIO (MkPromise <$> newIORef (Pending []) <*> newIORef 0 <*> newIORef (pure ()))
  -- a sentinel in the scope of the producer: it never ends by itself, is ended
  -- when the result is in, and abandons the promise when the scope is cancelled
  spawn (Async (\_, done => do
           writeIORef p.guard (done ())
           pure (MkCancel (settle p Abandoned Nothing))))
  spawn (Seq t (\a => Point (do settle p (Fulfilled a) (Just a)
                                end <- readIORef p.guard
                                end)))
  pure p

||| Wait for the result of a forked task: `Nothing` if it was given up.
export
waitMaybe : Promise a -> Task (Maybe a)
waitMaybe p = Async (\_, done => do
  st <- readIORef p.state
  case st of
    Fulfilled a => done (Just a) *> pure noCancel
    Abandoned => done Nothing *> pure noCancel
    Pending ws => do
      ident <- readIORef p.counter
      writeIORef p.counter (S ident)
      writeIORef p.state (Pending (ws ++ [(ident, done)]))
      pure (MkCancel (modifyIORef p.state (\s => case s of
                                                    Pending xs => Pending (filter (\w => fst w /= ident) xs)
                                                    other => other))))

||| Wait for the result of a forked task. If the task was given up, this task
||| never ends (it is as `Empty`; a `race` can give it another way out).
export
wait : Promise a -> Task a
wait p = Seq (waitMaybe p) (\r => case r of
                                     Just a => pure a
                                     Nothing => Empty)

||| The result if it is there, without waiting.
export
peek : Promise a -> Task (Maybe a)
peek p = Point (do st <- readIORef p.state
                   pure (case st of
                           Fulfilled a => Just a
                           _ => Nothing))
