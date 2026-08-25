module System.Concurrency.RC2

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import System.Concurrency

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

-- Channel: patched the same way as everything else above, now that
-- Just's representation can be relied on directly (see concurrency_util.c's
-- idris2rc2_channel_get_non_blocking/_get_with_timeout for the exact
-- assumption and its limits -- this is a narrower, sound thing than the
-- general "unwrap Just x to x" idea TODO.md records as dropped: here we
-- *build* a real tag=1/arity=1 Constructor for Prelude.Maybe specifically,
-- never elide one for an arbitrary payload type).
%foreign_impl System.Concurrency.prim__makeChannel
  "RC2:idris2rc2_channel_make,libidris2rc2base,concurrency_util.h"
%foreign_impl System.Concurrency.prim__channelGet
  "RC2:idris2rc2_channel_get,libidris2rc2base,concurrency_util.h"
%foreign_impl System.Concurrency.prim__channelGetNonBlocking
  "RC2:idris2rc2_channel_get_non_blocking,libidris2rc2base,concurrency_util.h"
%foreign_impl System.Concurrency.prim__channelGetWithTimeout
  "RC2:idris2rc2_channel_get_with_timeout,libidris2rc2base,concurrency_util.h"
%foreign_impl System.Concurrency.prim__channelPut
  "RC2:idris2rc2_channel_put,libidris2rc2base,concurrency_util.h"
