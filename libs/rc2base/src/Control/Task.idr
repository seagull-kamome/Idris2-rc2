||| Cooperative tasks: a monad of logical threads run by the scheduler of
||| `Control.Task.Scheduler`, after idris2-coop. A `Task` is a data structure
||| built by `>>=`, `both`, `race` and `spawn`; waiting for a descriptor, a
||| timer or any other asynchronous operation is `Async`. Design and
||| semantics: libs/rc2base/doc/task.md.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Control.Task

import System.Linux.Epoll
import System.Posix.FileDesc

%default covering

-------------------------------------------------------------------------------
-- The data type

||| A point on the monotonic clock, in milliseconds.
public export
Time : Type
Time = Nat

||| What gives an operation up. It has two constructors on purpose: a bare
||| `IO ()`, or a type with one constructor and one field (which Idris2 compiles
||| to its field), makes `IO Cancel` an action that returns an action, and
||| rc2's world arity raising then runs the effects of the operation's start too
||| late (KNOWN-BUGS.md).
public export
data Cancel = MkCancel (IO ()) | NoCancel

||| Nothing to give up.
public export
noCancel : Cancel
noCancel = NoCancel

||| Give the operation up.
export
runCancel : Cancel -> IO ()
runCancel (MkCancel act) = act
runCancel NoCancel = pure ()

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

||| Do it again and again.
export
forever : Task a -> Task b
forever t = Seq t (\_ => forever t)
