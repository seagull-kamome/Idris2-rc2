module System.Concurrency.RC2

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import System.Concurrency
import Data.IORef

-- This module defines its own Channel (see the "Channel" section below,
-- for why upstream's own type can't be reused) with the same names as
-- upstream's -- hidden here so this file's own definitions aren't
-- ambiguous against the imported ones. A downstream importer of *both*
-- modules still needs a qualified name; that's the documented tradeoff.
%hide System.Concurrency.Channel
%hide System.Concurrency.makeChannel
%hide System.Concurrency.channelPut
%hide System.Concurrency.channelGet
%hide System.Concurrency.channelGetNonBlocking
%hide System.Concurrency.channelGetWithTimeout

%foreign_impl System.Concurrency.prim__makeMutex
  "RC2:idris2rc2_mutex_make,libidris2rc2base,concurrency_util.h"
%foreign_impl System.Concurrency.prim__mutexAcquire
  "RC2:idris2rc2_mutex_acquire,libidris2rc2base,concurrency_util.h"
%foreign_impl System.Concurrency.prim__mutexRelease
  "RC2:idris2rc2_mutex_release,libidris2rc2base,concurrency_util.h"
%foreign_impl System.Concurrency.prim__makeCondition
  "RC2:idris2rc2_condition_make,libidris2rc2base,concurrency_util.h"
%foreign_impl System.Concurrency.prim__conditionWait
  "RC2:idris2rc2_condition_wait,libidris2rc2base,concurrency_util.h"
%foreign_impl System.Concurrency.prim__conditionSignal
  "RC2:idris2rc2_condition_signal,libidris2rc2base,concurrency_util.h"
%foreign_impl System.Concurrency.prim__conditionBroadcast
  "RC2:idris2rc2_condition_broadcast,libidris2rc2base,concurrency_util.h"
%foreign_impl System.Concurrency.prim__conditionWaitTimeout
  "RC2:idris2rc2_condition_wait_timeout,libidris2rc2base,concurrency_util.h"
%foreign_impl System.Concurrency.prim__getThreadId
  "RC2:idris2rc2_get_thread_id,libidris2rc2base,concurrency_util.h"
%foreign_impl System.Concurrency.prim__setThreadData
  "RC2:idris2rc2_set_thread_data,libidris2rc2base,concurrency_util.h"
%foreign_impl System.Concurrency.prim__getThreadData
  "RC2:idris2rc2_get_thread_data,libidris2rc2base,concurrency_util.h"
%foreign_impl System.Concurrency.prim__makeSemaphore
  "RC2:idris2rc2_semaphore_make,libidris2rc2base,concurrency_util.h"
%foreign_impl System.Concurrency.prim__semaphorePost
  "RC2:idris2rc2_semaphore_post,libidris2rc2base,concurrency_util.h"
%foreign_impl System.Concurrency.prim__semaphoreWait
  "RC2:idris2rc2_semaphore_wait,libidris2rc2base,concurrency_util.h"
%foreign_impl System.Concurrency.prim__makeBarrier
  "RC2:idris2rc2_barrier_make,libidris2rc2base,concurrency_util.h"
%foreign_impl System.Concurrency.prim__barrierWait
  "RC2:idris2rc2_barrier_wait,libidris2rc2base,concurrency_util.h"

-- rc2-specific joinable fork: upstream System.Concurrency.idr's ThreadID/
-- threadWait can't join anything from any C backend (threadWait is
-- scheme-only), so this is a fresh declaration, not a %foreign_impl
-- patch onto an existing one.
export
data JoinHandle : Type -> Type where [external]

%foreign "RC2:idris2rc2_fork_join,libidris2rc2base,concurrency_util.h"
prim__forkJoin : (1 prog : PrimIO a) -> PrimIO (JoinHandle a)

||| Like `fork`, but returns a handle that `join` can block on to collect
||| the forked computation's result -- unlike `ThreadID`, this is
||| actually usable from rc2 (`threadWait` never was). `join` must be
||| called at most once per handle (same lack of a type-enforced
||| uniqueness guarantee as upstream System.Concurrency's own API).
export
forkJoin : HasIO io => IO a -> io (JoinHandle a)
forkJoin act = primIO (prim__forkJoin (toPrim act))

%foreign "RC2:idris2rc2_join,libidris2rc2base,concurrency_util.h"
prim__join : JoinHandle a -> PrimIO a

||| Blocks until the thread started by `forkJoin` finishes, returning its
||| result.
export
join : HasIO io => JoinHandle a -> io a
join h = primIO (prim__join h)

-- Channel: upstream's own `Channel`/`makeChannel`/... are scheme-only
-- (like everything else patched above), but channelGetNonBlocking/
-- channelGetWithTimeout return `Maybe a` -- rc2 has no way to construct
-- an arbitrary program's `Just` tag from generic runtime C (only
-- `Nothing`'s NULL representation is a fixed, program-independent
-- convention). So Channel is implemented here in ordinary Idris on top
-- of the Mutex/Condition/IORef primitives above instead of patched via
-- %foreign_impl -- Maybe/List construction then goes through the normal
-- compiler pipeline, never across an FFI boundary. This also means it's
-- a fresh declaration (upstream's own `Channel` type can't be reused,
-- since giving an `[external]` type a concrete Idris-level constructor
-- from a different module isn't possible), so importing both this
-- module and System.Concurrency ambiguates `Channel` -- use a qualified
-- name if you need both.
export
data Channel : Type -> Type where
  MkChannel : IORef (List a) -> Mutex -> Condition -> Channel a

||| Creates and returns a new `Channel`.
export
makeChannel : HasIO io => io (Channel a)
makeChannel = do
  ref <- newIORef []
  mtx <- makeMutex
  cv <- makeCondition
  pure (MkChannel ref mtx cv)

||| Puts a value on the given channel.
export
channelPut : HasIO io => Channel a -> a -> io ()
channelPut (MkChannel ref mtx cv) val = do
  mutexAcquire mtx
  modifyIORef ref (++ [val])
  conditionSignal cv
  mutexRelease mtx

||| Blocks until a value is available on `chan`, then returns it.
export
covering
channelGet : HasIO io => Channel a -> io a
channelGet (MkChannel ref mtx cv) = do
  mutexAcquire mtx
  result <- loop
  mutexRelease mtx
  pure result
  where
    covering
    loop : io a
    loop = do
      xs <- readIORef ref
      case xs of
        [] => do conditionWait cv mtx; loop
        (x :: rest) => do writeIORef ref rest; pure x

||| Non-blocking version of `channelGet`.
export
channelGetNonBlocking : HasIO io => Channel a -> io (Maybe a)
channelGetNonBlocking (MkChannel ref mtx cv) = do
  mutexAcquire mtx
  xs <- readIORef ref
  result <- case xs of
    [] => pure Nothing
    (x :: rest) => do writeIORef ref rest; pure (Just x)
  mutexRelease mtx
  pure result

||| Timeout version of `channelGet`. A single `conditionWaitTimeout`
||| covers the whole budget -- if woken (spuriously or by a `channelPut`)
||| before a value is actually available, this returns `Nothing` rather
||| than re-waiting for the remainder, a deliberately simple first-pass
||| semantics rather than exact deadline tracking.
export
channelGetWithTimeout : HasIO io => Channel a -> (milliseconds : Nat) -> io (Maybe a)
channelGetWithTimeout (MkChannel ref mtx cv) milliseconds = do
  mutexAcquire mtx
  xs <- readIORef ref
  result <- case xs of
    (x :: rest) => do writeIORef ref rest; pure (Just x)
    [] => do
      conditionWaitTimeout cv mtx (cast milliseconds * 1000)
      xs' <- readIORef ref
      case xs' of
        [] => pure Nothing
        (x :: rest) => do writeIORef ref rest; pure (Just x)
  mutexRelease mtx
  pure result
